import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Wire framing for a forward-secret message body. Sits inside a transport
/// envelope, after the 1-byte cipher tag (0x02) that tells the receiver to
/// take this path instead of SealedBox.
///
/// Layout:
/// ```
///   [sender identity X25519 pub : 32]
///   [sender ephemeral X25519 pub : 32]
///   [nonce : 12]
///   [ChaCha20-Poly1305 ciphertext+tag : N]
/// ```
///
/// The 32-byte key is derived out-of-band via X3DH (see [X3dh]); this module
/// only does the AEAD + framing. The sender's identity + ephemeral publics
/// travel in the clear so the receiver can run the matching X3DH derivation;
/// they're not authenticated by this layer, but a wrong value yields a wrong
/// key and the AEAD tag check fails — and the inner payload is itself a
/// signed (Ed25519) SignedPayload, so sender identity is verified after
/// decryption regardless.
class FsMessage {
  FsMessage._();

  static const int pubLen = 32;
  static const int nonceLen = 12;
  static const int headerLen = pubLen + pubLen + nonceLen;

  static final _aead = Chacha20.poly1305Aead();

  /// Encrypt [plaintext] under [key], framing in the sender's identity +
  /// ephemeral publics. Returns the body bytes (the caller prepends the
  /// 0x02 cipher tag).
  static Future<Uint8List> seal({
    required SecretKey key,
    required Uint8List plaintext,
    required Uint8List senderIdentityPub,
    required Uint8List senderEphemeralPub,
  }) async {
    if (senderIdentityPub.length != pubLen ||
        senderEphemeralPub.length != pubLen) {
      throw ArgumentError('sender pubs must be $pubLen bytes');
    }
    final nonce = _aead.newNonce();
    final box = await _aead.encrypt(plaintext, secretKey: key, nonce: nonce);
    final out = Uint8List(headerLen + box.cipherText.length + 16);
    var c = 0;
    out.setRange(c, c += pubLen, senderIdentityPub);
    out.setRange(c, c += pubLen, senderEphemeralPub);
    out.setRange(c, c += nonceLen, nonce);
    out.setRange(c, c += box.cipherText.length, box.cipherText);
    out.setRange(c, out.length, box.mac.bytes);
    return out;
  }

  /// Parse the cleartext header so the caller can run X3DH before decrypt.
  static FsParsed parse(Uint8List body) {
    if (body.length < headerLen + 16) {
      throw const FormatException('fs message shorter than header+tag');
    }
    var c = 0;
    final ik = Uint8List.fromList(body.sublist(c, c += pubLen));
    final ek = Uint8List.fromList(body.sublist(c, c += pubLen));
    final nonce = Uint8List.fromList(body.sublist(c, c += nonceLen));
    final ctEnd = body.length - 16;
    final ct = Uint8List.fromList(body.sublist(c, ctEnd));
    final mac = Uint8List.fromList(body.sublist(ctEnd));
    return FsParsed(
      senderIdentityPub: ik,
      senderEphemeralPub: ek,
      nonce: nonce,
      ciphertext: ct,
      mac: mac,
    );
  }

  /// Decrypt a parsed body with the X3DH-derived [key]. Throws on a bad tag
  /// (wrong key / tampering).
  static Future<Uint8List> open({
    required SecretKey key,
    required FsParsed parsed,
  }) async {
    final box = SecretBox(
      parsed.ciphertext,
      nonce: parsed.nonce,
      mac: Mac(parsed.mac),
    );
    final clear = await _aead.decrypt(box, secretKey: key);
    return Uint8List.fromList(clear);
  }
}

class FsParsed {
  FsParsed({
    required this.senderIdentityPub,
    required this.senderEphemeralPub,
    required this.nonce,
    required this.ciphertext,
    required this.mac,
  });

  final Uint8List senderIdentityPub;
  final Uint8List senderEphemeralPub;
  final Uint8List nonce;
  final Uint8List ciphertext;
  final Uint8List mac;
}
