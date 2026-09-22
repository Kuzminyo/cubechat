import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../util/cost_meter.dart';

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

  /// From this many bytes up, a chunk is sealed and opened on an isolate of
  /// its own rather than on the one drawing the screen.
  ///
  /// The cipher is pure Dart and runs at about 13 MB/s on a phone: a 64 KiB
  /// relay chunk is ~5 ms of one block, and a video goes out at a dozen of
  /// those a second. The 1105 log of a 115 MB video had `media-seal 60×
  /// 300 ms` in every five seconds — a frame's worth of the UI thread gone,
  /// twelve times a second, reported as "the app stutters hard". The work is
  /// the same on another isolate; it is just no longer in the way of a frame.
  ///
  /// Below the line the chunk stays here: a Bluetooth photo goes in 4 KiB
  /// pieces, each well under a millisecond, and spawning an isolate for one
  /// would cost more than it saves.
  static const int offloadBytes = 16 * 1024;

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
    final nonce = Uint8List.fromList(_aead.newNonce());
    if (plaintext.length >= offloadBytes) {
      final keyBytes = Uint8List.fromList(await key.extractBytes());
      return CostMeter.instance.measure(
        'media-seal',
        () => _sealElsewhere(keyBytes, mediaId, nonce, plaintext),
      );
    }
    // Timed — pure-Dart ChaCha20-Poly1305 on the UI isolate, once per chunk
    // of every photo, voice note and file. See CostMeter.
    final clock = Stopwatch()..start();
    final out = await _sealHere(key, mediaId, nonce, plaintext);
    CostMeter.instance.recordSync('media-seal', clock.elapsedMicroseconds);
    return out;
  }

  // Static and handed only bytes, so the closure [Isolate.run] copies carries
  // nothing but what the seal needs.
  static Future<Uint8List> _sealElsewhere(
    Uint8List keyBytes,
    Uint8List mediaId,
    Uint8List nonce,
    Uint8List plaintext,
  ) =>
      Isolate.run(
        () => _sealHere(SecretKey(keyBytes), mediaId, nonce, plaintext),
        debugName: 'media-seal',
      );

  static Future<Uint8List> _sealHere(
    SecretKey key,
    Uint8List mediaId,
    Uint8List nonce,
    Uint8List plaintext,
  ) async {
    final box = await Chacha20.poly1305Aead().encrypt(
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
    // The receiving half of [offloadBytes]: the phone a video is arriving on
    // opens the same dozen 64 KiB chunks a second.
    if (body.length >= offloadBytes) {
      final keyBytes = Uint8List.fromList(await key.extractBytes());
      return CostMeter.instance.measure(
        'media-open',
        () => _openElsewhere(keyBytes, body),
      );
    }
    final clock = Stopwatch()..start();
    final clear = await _openHere(key, body);
    CostMeter.instance.recordSync('media-open', clock.elapsedMicroseconds);
    return clear;
  }

  static Future<Uint8List> _openElsewhere(Uint8List keyBytes, Uint8List body) =>
      Isolate.run(
        () => _openHere(SecretKey(keyBytes), body),
        debugName: 'media-open',
      );

  static Future<Uint8List> _openHere(SecretKey key, Uint8List body) async {
    var c = 0;
    final mediaId = body.sublist(c, c += idLen);
    final nonce = body.sublist(c, c += nonceLen);
    final ctEnd = body.length - tagLen;
    final ct = body.sublist(c, ctEnd);
    final mac = body.sublist(ctEnd);
    final box = SecretBox(ct, nonce: nonce, mac: Mac(mac));
    final clear = await Chacha20.poly1305Aead()
        .decrypt(box, secretKey: key, aad: mediaId);
    return Uint8List.fromList(clear);
  }
}
