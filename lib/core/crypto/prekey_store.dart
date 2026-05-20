import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// A single-use X25519 prekey we publish so senders can give us forward
/// secrecy. The private half is deleted the first time someone uses it.
class OneTimePrekey {
  OneTimePrekey({required this.id, required this.keyPair, required this.pub});

  /// 32-bit identifier the sender echoes back so we know which private key
  /// to use (and then delete).
  final int id;
  final SimpleKeyPairData keyPair;
  final Uint8List pub;
}

/// The medium-lived signed prekey. Rotated periodically by the owner; the
/// Ed25519 [signature] over [pub] lets a sender confirm it belongs to the
/// claimed identity before trusting it for key agreement.
class SignedPrekey {
  SignedPrekey({
    required this.id,
    required this.keyPair,
    required this.pub,
    required this.signature,
  });

  final int id;
  final SimpleKeyPairData keyPair;
  final Uint8List pub;
  final Uint8List signature;
}

/// The *public* bundle a peer hands out so others can start a forward-secret
/// session with them: identity key, the current signed prekey (+ signature),
/// and zero-or-more one-time prekeys. A sender pops one one-time prekey id
/// from here, uses it once, and never reuses it.
class PrekeyBundlePublic {
  PrekeyBundlePublic({
    required this.identityPub,
    required this.signedPrekeyId,
    required this.signedPrekeyPub,
    required this.signedPrekeySig,
    required this.oneTimePrekeys, // id -> pub
  });

  final Uint8List identityPub;
  final int signedPrekeyId;
  final Uint8List signedPrekeyPub;
  final Uint8List signedPrekeySig;
  final Map<int, Uint8List> oneTimePrekeys;

  bool get hasOneTime => oneTimePrekeys.isNotEmpty;
}

/// Holds our own prekey private material and mints the public bundle.
///
/// One-time prekeys are consumed (deleted) on first use — that deletion is
/// the source of forward secrecy, so callers MUST [consumeOneTime] exactly
/// once per incoming X3DH message and never resurrect a consumed key.
///
/// This core keeps state in memory; the transport-wiring step is responsible
/// for persisting the private keys to the encrypted Hive box (so a restart
/// doesn't silently drop forward secrecy) and for re-signing a fresh signed
/// prekey on rotation.
class PrekeyStore {
  PrekeyStore({
    required this.identityKeyPair,
    required this.identityPub,
    required this.signKeyPair,
  });

  final SimpleKeyPairData identityKeyPair; // X25519 long-term
  final Uint8List identityPub;
  final SimpleKeyPairData signKeyPair; // Ed25519 for signing the SPK

  static final _x25519 = X25519();
  static final _ed25519 = Ed25519();

  SignedPrekey? _signedPrekey;
  final Map<int, OneTimePrekey> _oneTime = {};
  int _nextOpkId = 1;
  int _nextSpkId = 1;

  int get oneTimeCount => _oneTime.length;
  SignedPrekey? get currentSignedPrekey => _signedPrekey;

  /// (Re)generate the signed prekey, signing its public half with our
  /// Ed25519 identity. Call on first init and on each rotation.
  Future<void> rotateSignedPrekey() async {
    final kp = await _x25519.newKeyPair();
    final pub = Uint8List.fromList((await kp.extractPublicKey()).bytes);
    final priv = Uint8List.fromList(await kp.extractPrivateKeyBytes());
    final sig = await _ed25519.sign(pub, keyPair: signKeyPair);
    _signedPrekey = SignedPrekey(
      id: _nextSpkId++,
      keyPair: SimpleKeyPairData(
        priv,
        publicKey: SimplePublicKey(pub, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      ),
      pub: pub,
      signature: Uint8List.fromList(sig.bytes),
    );
  }

  /// Mint [count] fresh one-time prekeys, adding them to the pool.
  Future<void> replenishOneTime(int count) async {
    for (var i = 0; i < count; i++) {
      final kp = await _x25519.newKeyPair();
      final pub = Uint8List.fromList((await kp.extractPublicKey()).bytes);
      final priv = Uint8List.fromList(await kp.extractPrivateKeyBytes());
      final id = _nextOpkId++;
      _oneTime[id] = OneTimePrekey(
        id: id,
        keyPair: SimpleKeyPairData(
          priv,
          publicKey: SimplePublicKey(pub, type: KeyPairType.x25519),
          type: KeyPairType.x25519,
        ),
        pub: pub,
      );
    }
  }

  /// Build the public bundle we hand out. Includes up to [maxOneTime]
  /// one-time prekey publics (senders take one each).
  PrekeyBundlePublic publicBundle({int maxOneTime = 20}) {
    final spk = _signedPrekey;
    if (spk == null) {
      throw StateError('signed prekey not generated — call rotateSignedPrekey');
    }
    final opks = <int, Uint8List>{};
    for (final e in _oneTime.entries) {
      if (opks.length >= maxOneTime) break;
      opks[e.key] = e.value.pub;
    }
    return PrekeyBundlePublic(
      identityPub: identityPub,
      signedPrekeyId: spk.id,
      signedPrekeyPub: spk.pub,
      signedPrekeySig: spk.signature,
      oneTimePrekeys: opks,
    );
  }

  /// Look up (without consuming) a one-time prekey by id — used to derive
  /// the receiver key. Returns null if already consumed / never existed.
  OneTimePrekey? oneTimeById(int id) => _oneTime[id];

  /// Permanently delete the one-time prekey [id]. THIS is the forward-secrecy
  /// step: once gone, the per-message key can't be reconstructed. Returns the
  /// key pair so the caller can derive the receiver key in the same breath.
  OneTimePrekey? consumeOneTime(int id) => _oneTime.remove(id);

  /// Verify a signed-prekey signature against an identity's Ed25519 key.
  /// Senders call this before trusting a peer's bundle.
  static Future<bool> verifySignedPrekey({
    required Uint8List signedPrekeyPub,
    required Uint8List signature,
    required Uint8List signerEd25519Pub,
  }) async {
    return _ed25519.verify(
      signedPrekeyPub,
      signature: Signature(
        signature,
        publicKey:
            SimplePublicKey(signerEd25519Pub, type: KeyPairType.ed25519),
      ),
    );
  }
}
