import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../crypto/secp256k1.dart';
import 'nostr_event.dart';
import 'nostr_transport.dart';

/// Concrete [NostrEventSigner] backed by the pure-Dart [Secp256k1] BIP-340
/// implementation.
///
/// The secp256k1 key is **deterministically derived** from the cubechat
/// identity's Ed25519 seed, so the same identity always maps to the same Nostr
/// pubkey (`npub`) across restarts and devices without persisting any extra key
/// material:
///
/// ```
///   ikm     = ed25519_identity_seed        (32 bytes)
///   okm     = HKDF-SHA256(ikm, salt="", info="cubechat/nostr-secp256k1/v1", 32)
///   scalar  = (int(okm) mod (n-1)) + 1     // always in [1, n-1]
///   npub    = x-only(scalar · G)
/// ```
///
/// The `(mod n-1) + 1` reduction can never yield 0 or a value ≥ n, so the
/// derived scalar is always a valid BIP-340 secret key (the tiny modular bias
/// is ~2^-128 and irrelevant here).
class Secp256k1NostrSigner implements NostrEventSigner {
  Secp256k1NostrSigner._(this._secretKey, this.npubHex);

  final Uint8List _secretKey;

  @override
  final String npubHex;

  static const String _derivationInfo = 'cubechat/nostr-secp256k1/v1';
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final _rand = Random.secure();

  /// Derive the signer from a 32-byte Ed25519 identity seed
  /// ([IdentityKeys.signPrivateKey]).
  static Future<Secp256k1NostrSigner> deriveFromSeed(Uint8List ed25519Seed) async {
    final scalar = await _deriveScalar(ed25519Seed);
    final pub = Secp256k1.xonlyPubkey(scalar);
    return Secp256k1NostrSigner._(scalar, _hex(pub));
  }

  @override
  Future<NostrEvent> sign(NostrEvent event) async {
    final withId = await event.withId();
    final idBytes = _unhex(withId.id!);
    final aux = _randomBytes(32);
    final sig = await Secp256k1.sign(
      secretKey: _secretKey,
      message: idBytes,
      auxRand: aux,
    );
    return withId.copyWith(sig: _hex(sig));
  }

  static Future<Uint8List> _deriveScalar(Uint8List seed) async {
    final okm = await _hkdf.deriveKey(
      secretKey: SecretKey(seed),
      nonce: const <int>[], // empty salt
      info: _derivationInfo.codeUnits,
    );
    final okmBytes = Uint8List.fromList(await okm.extractBytes());
    var candidate = BigInt.zero;
    for (final b in okmBytes) {
      candidate = (candidate << 8) | BigInt.from(b);
    }
    final scalar = (candidate % (Secp256k1.n - BigInt.one)) + BigInt.one;
    return _bytes32(scalar);
  }

  static Uint8List _randomBytes(int n) {
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[i] = _rand.nextInt(256);
    }
    return out;
  }

  static Uint8List _bytes32(BigInt v) {
    final out = Uint8List(32);
    var x = v;
    for (var i = 31; i >= 0; i--) {
      out[i] = (x & BigInt.from(0xff)).toInt();
      x = x >> 8;
    }
    return out;
  }

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _unhex(String s) {
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
