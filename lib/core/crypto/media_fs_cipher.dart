import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Per-chunk AEAD for a **forward-secret media transfer**.
///
/// One X3DH-derived key covers the whole transfer (the X3DH setup — the
/// sender's ephemeral — rides once in the signed [MediaManifest]). Each chunk
/// is sealed under that key with a fresh random nonce carried in the clear, so
/// the per-chunk overhead is just `mediaId(16) + nonce(12) + tag(16) = 44 B` —
/// smaller than the SealedBox path's 48 B, so it never worsens the BLE MTU
/// budget. Crucially there are **no per-chunk public keys**: those would blow
/// the MTU.
///
/// The `mediaId` travels in the clear (it's a random id, not sensitive) so the
/// receiver can look up the transfer's key before decrypting, and is bound as
/// AEAD associated data so a relay can't graft a chunk onto a different
/// transfer under the same key.
///
/// Wire layout of a sealed chunk body (sits after the 1-byte cipher tag):
/// ```
///   [mediaId : 16][nonce : 12][ChaCha20-Poly1305 ciphertext+tag : N+16]
/// ```
class MediaFsCipher {
  MediaFsCipher._();

  static const int idLen = 16;
  static const int nonceLen = 12;
  static const int tagLen = 16;
  static const int headerLen = idLen + nonceLen;

  static final _aead = Chacha20.poly1305Aead();

  /// Seal [plaintext] (a chunk's inner bytes) under [key] for transfer
  /// [mediaId] (16 bytes). Returns `mediaId || nonce || ct || tag`.
  static Future<Uint8List> seal({
    required SecretKey key,
    required Uint8List mediaId,
    required Uint8List plaintext,
  }) async {
    if (mediaId.length != idLen) {
      throw ArgumentError('mediaId must be $idLen bytes');
    }
    final nonce = _aead.newNonce();
    final box = await _aead.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: mediaId,
    );
    final out = Uint8List(headerLen + box.cipherText.length + tagLen);
    var c = 0;
    out.setRange(c, c += idLen, mediaId);
    out.setRange(c, c += nonceLen, nonce);
    out.setRange(c, c += box.cipherText.length, box.cipherText);
    out.setRange(c, out.length, box.mac.bytes);
    return out;
  }

  /// The transfer id a sealed [body] belongs to, so the caller can look up the
  /// right key before [open]. Throws [FormatException] if the body is too
  /// short to carry a header.
  static Uint8List readMediaId(Uint8List body) {
    if (body.length < headerLen + tagLen) {
      throw const FormatException('fs media chunk shorter than header+tag');
    }
    return Uint8List.fromList(body.sublist(0, idLen));
  }

  /// Open a sealed [body] with the transfer's [key]. Throws on a bad tag
  /// (wrong key / tampering / grafted mediaId).
  static Future<Uint8List> open({
    required SecretKey key,
    required Uint8List body,
  }) async {
    if (body.length < headerLen + tagLen) {
      throw const FormatException('fs media chunk shorter than header+tag');
    }
    var c = 0;
    final mediaId = body.sublist(c, c += idLen);
    final nonce = body.sublist(c, c += nonceLen);
    final ctEnd = body.length - tagLen;
    final ct = body.sublist(c, ctEnd);
    final mac = body.sublist(ctEnd);
    final box = SecretBox(ct, nonce: nonce, mac: Mac(mac));
    final clear = await _aead.decrypt(box, secretKey: key, aad: mediaId);
    return Uint8List.fromList(clear);
  }
}
