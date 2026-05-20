import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// X3DH (Extended Triple Diffie-Hellman) key agreement — the asynchronous
/// key exchange behind Signal's forward secrecy, adapted to cubechat's
/// serverless BLE mesh.
///
/// Why this and not the existing SealedBox: SealedBox encrypts to a peer's
/// *long-term* X25519 key, so if that key is ever compromised, every past
/// message to that peer can be decrypted. X3DH mixes in a freshly-rotated
/// signed prekey and a single-use one-time prekey; the receiver deletes the
/// one-time prekey immediately after use, so the per-message key can never
/// be reconstructed later even if the long-term key leaks. That's forward
/// secrecy.
///
/// Roles:
///   * IK  — long-term identity X25519 key (we already have this).
///   * SPK — signed prekey: medium-lived X25519 key, signed by the owner's
///           Ed25519 identity so the sender can trust it.
///   * OPK — one-time prekey: single-use X25519 key, deleted after first use.
///   * EK  — sender's per-message ephemeral X25519 key.
///
/// The four DHs (DH4 only when an OPK is available):
///   DH1 = DH(IK_sender, SPK_recipient)
///   DH2 = DH(EK_sender, IK_recipient)
///   DH3 = DH(EK_sender, SPK_recipient)
///   DH4 = DH(EK_sender, OPK_recipient)
/// SK = HKDF-SHA256(DH1 || DH2 || DH3 [|| DH4]).
///
/// DH is symmetric, so the recipient recomputes the same secrets with the
/// private halves it holds — see [deriveReceiver].
class X3dh {
  X3dh._();

  static final _x25519 = X25519();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  /// Domain-separation salt + info. Distinct from SealedBox's so a key from
  /// one construction can never collide with the other.
  static const List<int> _info = [
    0x63, 0x75, 0x62, 0x65, 0x63, 0x68, 0x61, 0x74, // "cubechat"
    0x2d, 0x78, 0x33, 0x64, 0x68, 0x2d, 0x76, 0x31, // "-x3dh-v1"
  ];

  /// Sender side. [ identityPriv ] is our long-term X25519 key pair;
  /// [ephemeral] is a fresh per-message X25519 key pair. The recipient's
  /// public keys come from their prekey bundle. Returns the 32-byte
  /// agreed key. Pass [recipientOneTimePub] = null only when the bundle
  /// had no one-time prekeys left (weaker — still forward-secret via SPK
  /// rotation, but not per-message unique).
  static Future<SecretKey> deriveSender({
    required SimpleKeyPairData identityKeyPair,
    required SimpleKeyPairData ephemeralKeyPair,
    required Uint8List recipientIdentityPub,
    required Uint8List recipientSignedPrekeyPub,
    Uint8List? recipientOneTimePub,
  }) async {
    final dh1 = await _dh(identityKeyPair, recipientSignedPrekeyPub);
    final dh2 = await _dh(ephemeralKeyPair, recipientIdentityPub);
    final dh3 = await _dh(ephemeralKeyPair, recipientSignedPrekeyPub);
    final parts = <int>[...dh1, ...dh2, ...dh3];
    if (recipientOneTimePub != null) {
      parts.addAll(await _dh(ephemeralKeyPair, recipientOneTimePub));
    }
    return _kdf(parts);
  }

  /// Receiver side. Recomputes the identical key from the private halves of
  /// the prekeys the sender selected, plus the sender's identity + ephemeral
  /// public keys carried in the message header. [oneTimeKeyPair] must be
  /// non-null iff the sender used an OPK.
  static Future<SecretKey> deriveReceiver({
    required SimpleKeyPairData identityKeyPair,
    required SimpleKeyPairData signedPrekeyPair,
    SimpleKeyPairData? oneTimeKeyPair,
    required Uint8List senderIdentityPub,
    required Uint8List senderEphemeralPub,
  }) async {
    final dh1 = await _dh(signedPrekeyPair, senderIdentityPub);
    final dh2 = await _dh(identityKeyPair, senderEphemeralPub);
    final dh3 = await _dh(signedPrekeyPair, senderEphemeralPub);
    final parts = <int>[...dh1, ...dh2, ...dh3];
    if (oneTimeKeyPair != null) {
      parts.addAll(await _dh(oneTimeKeyPair, senderEphemeralPub));
    }
    return _kdf(parts);
  }

  static Future<List<int>> _dh(
    SimpleKeyPairData ours,
    Uint8List theirPub,
  ) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: ours,
      remotePublicKey: SimplePublicKey(theirPub, type: KeyPairType.x25519),
    );
    return shared.extractBytes();
  }

  static Future<SecretKey> _kdf(List<int> material) {
    return _hkdf.deriveKey(
      secretKey: SecretKey(material),
      nonce: const [], // HKDF salt: empty (the DH material is the entropy)
      info: _info,
    );
  }
}
