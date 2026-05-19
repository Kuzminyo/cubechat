import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Anonymous public-key encryption: a sender can encrypt a payload to a
/// recipient's static X25519 public key without holding any prior shared
/// state. Mirrors the libsodium `crypto_box_seal` construction.
///
/// Why we need it: relays inside the mesh don't share Noise sessions with
/// the ultimate destination. If A wants to message C via B, A must encrypt
/// for C — not for B — so B can forward without ever decrypting. SealedBox
/// is the standard primitive for that.
///
/// Wire layout:
///
/// ```
///   [ephemeral X25519 pubkey : 32 bytes]
///   [ChaCha20-Poly1305 ciphertext : N bytes]
///   [Poly1305 tag : 16 bytes]
/// ```
///
/// **Authentication caveat**: SealedBox is anonymous — anyone can encrypt
/// to a known pubkey. The recipient learns the contents but NOT who sent
/// them; the envelope's `originPubkeyHash` is purely a routing hint and is
/// unsigned. Sender authenticity is provided externally by the Noise XX
/// direct-link session (for immediate neighbors) or — once added — an
/// inner signature (for multi-hop). For M3.D we accept the anonymous
/// property; a follow-up milestone introduces signatures.
class SealedBox {
  SealedBox._();

  static const int ephemeralPubLen = 32;
  static const int tagLen = 16;
  static const int nonceLen = 12;
  static const int overhead = ephemeralPubLen + tagLen;

  static final _x25519 = X25519();
  static final _aead = Chacha20.poly1305Aead();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final _blake = Blake2s();

  /// Encrypt [plaintext] for the holder of [recipientPubkey] (32-byte X25519
  /// static public key). Returns the on-wire bytes (`ephemeral || ct || tag`).
  static Future<Uint8List> seal(
    Uint8List plaintext,
    Uint8List recipientPubkey,
  ) async {
    if (recipientPubkey.length != ephemeralPubLen) {
      throw ArgumentError('recipient pubkey must be $ephemeralPubLen B');
    }

    final ephemeral = await _x25519.newKeyPair();
    final ephemeralPub = await ephemeral.extractPublicKey();
    final ephemeralPubBytes = Uint8List.fromList(ephemeralPub.bytes);

    final shared = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey:
          SimplePublicKey(recipientPubkey, type: KeyPairType.x25519),
    );
    final key = await _deriveKey(shared, ephemeralPubBytes, recipientPubkey);
    final nonce = await _deriveNonce(ephemeralPubBytes, recipientPubkey);

    final secretBox = await _aead.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
    );

    final out = Uint8List(ephemeralPubLen + secretBox.cipherText.length + tagLen);
    out.setRange(0, ephemeralPubLen, ephemeralPubBytes);
    out.setRange(ephemeralPubLen, ephemeralPubLen + secretBox.cipherText.length,
        secretBox.cipherText);
    out.setRange(
      ephemeralPubLen + secretBox.cipherText.length,
      out.length,
      secretBox.mac.bytes,
    );
    return out;
  }

  /// Decrypt a sealed box destined for us. [recipientKeyPair] is our long-
  /// term identity keypair; [recipientPubkey] is the matching public key
  /// (passed separately because it's also used to derive the AEAD nonce).
  static Future<Uint8List> open(
    Uint8List wire, {
    required SimpleKeyPairData recipientKeyPair,
    required Uint8List recipientPubkey,
  }) async {
    if (wire.length < ephemeralPubLen + tagLen) {
      throw const FormatException('sealed box shorter than overhead');
    }
    final ephemeralPubBytes =
        Uint8List.fromList(wire.sublist(0, ephemeralPubLen));
    final ctEnd = wire.length - tagLen;
    final ciphertext = wire.sublist(ephemeralPubLen, ctEnd);
    final tag = wire.sublist(ctEnd);

    final shared = await _x25519.sharedSecretKey(
      keyPair: recipientKeyPair,
      remotePublicKey:
          SimplePublicKey(ephemeralPubBytes, type: KeyPairType.x25519),
    );
    final key = await _deriveKey(shared, ephemeralPubBytes, recipientPubkey);
    final nonce = await _deriveNonce(ephemeralPubBytes, recipientPubkey);

    final secretBox = SecretBox(
      ciphertext,
      nonce: nonce,
      mac: Mac(tag),
    );
    final plaintext = await _aead.decrypt(secretBox, secretKey: key);
    return Uint8List.fromList(plaintext);
  }

  /// HKDF over the raw ECDH shared secret, salted by both pubkeys so the
  /// derived key is bound to this specific (ephemeral, recipient) pair.
  static Future<SecretKey> _deriveKey(
    SecretKey shared,
    Uint8List ephemeralPub,
    Uint8List recipientPub,
  ) async {
    final salt = Uint8List(ephemeralPub.length + recipientPub.length);
    salt.setRange(0, ephemeralPub.length, ephemeralPub);
    salt.setRange(ephemeralPub.length, salt.length, recipientPub);
    return _hkdf.deriveKey(
      secretKey: shared,
      nonce: salt,
      info: const [0x63, 0x75, 0x62, 0x65, 0x63, 0x68, 0x61, 0x74], // "cubechat"
    );
  }

  /// Deterministic 12-byte nonce derived from BLAKE2s(ephemeral || recipient).
  /// Nonce reuse is structurally impossible because the ephemeral key is
  /// freshly generated for every seal().
  static Future<List<int>> _deriveNonce(
    Uint8List ephemeralPub,
    Uint8List recipientPub,
  ) async {
    final material = Uint8List(ephemeralPub.length + recipientPub.length);
    material.setRange(0, ephemeralPub.length, ephemeralPub);
    material.setRange(ephemeralPub.length, material.length, recipientPub);
    final hash = await _blake.hash(material);
    return hash.bytes.sublist(0, nonceLen);
  }
}
