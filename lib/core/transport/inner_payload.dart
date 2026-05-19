import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Inner-payload format carried *inside* the SealedBox ciphertext.
///
/// Before M5.4 we encrypted plain UTF-8 text and decoded the entire
/// plaintext as a string. M5.4 introduces multi-kind payloads (text + image
/// chunks) by prepending a 1-byte type tag:
///
/// ```
///   [type : 1 byte] [body : N bytes]
/// ```
///
/// Backwards compatibility: peers running pre-M5.4 builds will reject
/// anything they can't UTF-8-decode, which is the deliberate wire break
/// signalled by the build stamp bump.
enum InnerPayloadType {
  /// Plain UTF-8 text — replaces the implicit pre-M5.4 format.
  text(0x10),

  /// One slice of a chunked image transfer. See [ImageChunk].
  imageChunk(0x20),

  /// One slice of a chunked voice message. Same chunked-delivery scheme
  /// as image chunks; see [AudioChunk] for the wire layout.
  audioChunk(0x30),

  /// Signed manifest for a chunked media transfer. Carries mediaId, total
  /// chunks, mime, optional durationMs (audio) and a SHA-256 over the
  /// assembled bytes — sent *before* the chunks themselves. See
  /// [MediaManifest]. The manifest body lives inside a SignedPayload so
  /// the receiver knows it actually came from the claimed origin and
  /// can reject assembled bytes whose hash doesn't match the signed
  /// commitment.
  mediaManifest(0x50);

  const InnerPayloadType(this.tag);
  final int tag;

  static InnerPayloadType? fromByte(int b) {
    for (final v in InnerPayloadType.values) {
      if (v.tag == b) return v;
    }
    return null;
  }
}

/// Wrap [body] with the [type] tag. The result becomes the SealedBox
/// plaintext.
Uint8List packInnerPayload(InnerPayloadType type, Uint8List body) {
  final out = Uint8List(1 + body.length);
  out[0] = type.tag;
  out.setRange(1, out.length, body);
  return out;
}

/// Split a tagged inner payload back into (type, body). Throws
/// [FormatException] when the buffer is empty or the type byte is unknown.
({InnerPayloadType type, Uint8List body}) unpackInnerPayload(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const FormatException('inner payload is empty');
  }
  final type = InnerPayloadType.fromByte(bytes[0]);
  if (type == null) {
    throw FormatException(
        'unknown inner-payload type 0x${bytes[0].toRadixString(16)}');
  }
  return (
    type: type,
    body: Uint8List.fromList(bytes.sublist(1)),
  );
}

/// One slice of a chunked image transfer. Multiple chunks sharing the same
/// `imageId` reassemble (in seq order) into the original image bytes.
///
/// Wire layout (inside an [InnerPayloadType.imageChunk] body):
///
/// ```
///   [imageId  : 16 bytes]
///   [seq      :  2 bytes BE]   ← 0-based chunk index
///   [total    :  2 bytes BE]   ← number of chunks
///   [mimeLen  :  1 byte]
///   [mime     :  mimeLen bytes UTF-8]
///   [dataLen  :  2 bytes BE]
///   [data     :  dataLen bytes]
/// ```
///
/// We cap chunks at ~140 bytes of raw image data so a chunk + SealedBox +
/// TransportEnvelope + outer Frame stays inside Android's default 244-byte
/// negotiated MTU on lazy stacks.
class ImageChunk {
  ImageChunk({
    required this.imageId,
    required this.seq,
    required this.total,
    required this.mime,
    required this.data,
  })  : assert(imageId.length == idLen, 'imageId must be $idLen B'),
        assert(seq >= 0 && seq < 0x10000, 'seq out of u16 range'),
        assert(total >= 1 && total < 0x10000, 'total out of u16 range'),
        assert(seq < total, 'seq must be < total'),
        assert(data.length < 0x10000, 'chunk data too large for u16 length');

  final Uint8List imageId;
  final int seq;
  final int total;
  final String mime;
  final Uint8List data;

  static const int idLen = 16;

  /// Max raw image bytes per chunk. Keeps the full outer frame inside the
  /// Android default 244-byte effective MTU after envelope + SealedBox +
  /// inner-type + chunk header (~95 bytes of overhead at the upper bound).
  static const int maxDataBytes = 140;

  Uint8List encode() {
    final mimeBytes = utf8.encode(mime);
    if (mimeBytes.length > 255) {
      throw const FormatException('mime > 255 UTF-8 bytes');
    }
    final out = Uint8List(idLen + 2 + 2 + 1 + mimeBytes.length + 2 + data.length);
    var c = 0;
    out.setRange(c, c += idLen, imageId);
    out[c++] = (seq >> 8) & 0xff;
    out[c++] = seq & 0xff;
    out[c++] = (total >> 8) & 0xff;
    out[c++] = total & 0xff;
    out[c++] = mimeBytes.length;
    out.setRange(c, c += mimeBytes.length, mimeBytes);
    out[c++] = (data.length >> 8) & 0xff;
    out[c++] = data.length & 0xff;
    out.setRange(c, c += data.length, data);
    return out;
  }

  static ImageChunk decode(Uint8List bytes) {
    if (bytes.length < idLen + 2 + 2 + 1 + 2) {
      throw const FormatException('image chunk truncated');
    }
    var c = 0;
    final id = Uint8List.fromList(bytes.sublist(c, c += idLen));
    final seq = (bytes[c] << 8) | bytes[c + 1];
    c += 2;
    final total = (bytes[c] << 8) | bytes[c + 1];
    c += 2;
    final mimeLen = bytes[c++];
    if (bytes.length < c + mimeLen + 2) {
      throw const FormatException('image chunk mime overrun');
    }
    final mime = utf8.decode(
      bytes.sublist(c, c + mimeLen),
      allowMalformed: true,
    );
    c += mimeLen;
    final dataLen = (bytes[c] << 8) | bytes[c + 1];
    c += 2;
    if (bytes.length < c + dataLen) {
      throw const FormatException('image chunk data overrun');
    }
    final data = Uint8List.fromList(bytes.sublist(c, c + dataLen));
    return ImageChunk(
      imageId: id,
      seq: seq,
      total: total,
      mime: mime,
      data: data,
    );
  }

  static final _rand = Random.secure();

  /// Mint a fresh 16-byte image id (used to group chunks of the same image).
  static Uint8List newImageId() {
    final out = Uint8List(idLen);
    for (var i = 0; i < out.length; i++) {
      out[i] = _rand.nextInt(256);
    }
    return out;
  }
}

/// One slice of a chunked voice message. Mirrors [ImageChunk] but adds a
/// duration-millis field so the receiver can render the playback timer
/// from chunk #0 without waiting for the full audio to assemble.
///
/// Wire layout (inside an [InnerPayloadType.audioChunk] body):
///
/// ```
///   [audioId       : 16 bytes]
///   [seq           :  2 bytes BE]
///   [total         :  2 bytes BE]
///   [durationMs    :  4 bytes BE]   ← total audio length (same in every chunk)
///   [mimeLen       :  1 byte]
///   [mime          :  mimeLen bytes UTF-8]
///   [dataLen       :  2 bytes BE]
///   [data          :  dataLen bytes — opus/aac frames]
/// ```
class AudioChunk {
  AudioChunk({
    required this.audioId,
    required this.seq,
    required this.total,
    required this.durationMs,
    required this.mime,
    required this.data,
  })  : assert(audioId.length == idLen, 'audioId must be $idLen B'),
        assert(seq >= 0 && seq < 0x10000, 'seq out of u16 range'),
        assert(total >= 1 && total < 0x10000, 'total out of u16 range'),
        assert(seq < total, 'seq must be < total'),
        assert(durationMs >= 0 && durationMs <= 0xFFFFFFFF,
            'durationMs out of u32 range'),
        assert(data.length < 0x10000, 'chunk data too large for u16 length');

  final Uint8List audioId;
  final int seq;
  final int total;
  final int durationMs;
  final String mime;
  final Uint8List data;

  static const int idLen = 16;

  /// Max raw audio bytes per chunk. Slightly smaller than image's 140 to
  /// leave room for the duration field; still fits inside MTU=256.
  static const int maxDataBytes = 136;

  Uint8List encode() {
    final mimeBytes = utf8.encode(mime);
    if (mimeBytes.length > 255) {
      throw const FormatException('mime > 255 UTF-8 bytes');
    }
    final out = Uint8List(
      idLen + 2 + 2 + 4 + 1 + mimeBytes.length + 2 + data.length,
    );
    var c = 0;
    out.setRange(c, c += idLen, audioId);
    out[c++] = (seq >> 8) & 0xff;
    out[c++] = seq & 0xff;
    out[c++] = (total >> 8) & 0xff;
    out[c++] = total & 0xff;
    out[c++] = (durationMs >> 24) & 0xff;
    out[c++] = (durationMs >> 16) & 0xff;
    out[c++] = (durationMs >> 8) & 0xff;
    out[c++] = durationMs & 0xff;
    out[c++] = mimeBytes.length;
    out.setRange(c, c += mimeBytes.length, mimeBytes);
    out[c++] = (data.length >> 8) & 0xff;
    out[c++] = data.length & 0xff;
    out.setRange(c, c += data.length, data);
    return out;
  }

  static AudioChunk decode(Uint8List bytes) {
    if (bytes.length < idLen + 2 + 2 + 4 + 1 + 2) {
      throw const FormatException('audio chunk truncated');
    }
    var c = 0;
    final id = Uint8List.fromList(bytes.sublist(c, c += idLen));
    final seq = (bytes[c] << 8) | bytes[c + 1];
    c += 2;
    final total = (bytes[c] << 8) | bytes[c + 1];
    c += 2;
    final durMs = (bytes[c] << 24) |
        (bytes[c + 1] << 16) |
        (bytes[c + 2] << 8) |
        bytes[c + 3];
    c += 4;
    final mimeLen = bytes[c++];
    if (bytes.length < c + mimeLen + 2) {
      throw const FormatException('audio chunk mime overrun');
    }
    final mime = utf8.decode(
      bytes.sublist(c, c + mimeLen),
      allowMalformed: true,
    );
    c += mimeLen;
    final dataLen = (bytes[c] << 8) | bytes[c + 1];
    c += 2;
    if (bytes.length < c + dataLen) {
      throw const FormatException('audio chunk data overrun');
    }
    final data = Uint8List.fromList(bytes.sublist(c, c + dataLen));
    return AudioChunk(
      audioId: id,
      seq: seq,
      total: total,
      durationMs: durMs,
      mime: mime,
      data: data,
    );
  }

  static final _rand = Random.secure();

  static Uint8List newAudioId() {
    final out = Uint8List(idLen);
    for (var i = 0; i < out.length; i++) {
      out[i] = _rand.nextInt(256);
    }
    return out;
  }
}

/// What kind of media the [MediaManifest] commits to. Encoded as a single
/// byte; new kinds get appended without breaking older readers (an unknown
/// kind throws on decode and the manifest is dropped).
enum MediaKind {
  image(0x10),
  audio(0x30);

  const MediaKind(this.tag);
  final int tag;

  static MediaKind fromByte(int b) {
    for (final v in MediaKind.values) {
      if (v.tag == b) return v;
    }
    throw FormatException(
        'unknown media kind 0x${b.toRadixString(16)}');
  }
}

/// Signed commitment to a chunked-media payload. Sender computes a SHA-256
/// over the assembled bytes, packs them into this struct, wraps it in a
/// SignedPayload, and ships it as the **first** frame of the media stream.
///
/// Wire layout (lives inside an [InnerPayloadType.mediaManifest] body —
/// itself inside a SignedPayload + SealedBox + envelope):
///
/// ```
///   [ver          : 1 byte = 0x01]
///   [mediaId      : 16 bytes — same id as the chunks]
///   [kind         : 1 byte  — MediaKind tag]
///   [total        : 2 bytes BE — chunk count]
///   [durationMs   : 4 bytes BE — audio only, 0 for image]
///   [mimeLen      : 1 byte]
///   [mime         : mimeLen bytes UTF-8]
///   [sha256       : 32 bytes — over the assembled raw bytes]
/// ```
///
/// Receiver pairs the manifest with the assembled bytes (by mediaId);
/// the SHA-256 check rejects any frame stream where a relay swapped or
/// reordered chunks under the right id (SealedBox-AEAD already prevents
/// flipping bytes *inside* a chunk, but the manifest commitment defends
/// against substitution at the chunk granularity).
class MediaManifest {
  MediaManifest({
    required this.mediaId,
    required this.kind,
    required this.total,
    required this.mime,
    required this.sha256,
    this.durationMs = 0,
  })  : assert(mediaId.length == idLen, 'mediaId must be $idLen B'),
        assert(total >= 1 && total < 0x10000, 'total out of u16 range'),
        assert(durationMs >= 0 && durationMs <= 0xFFFFFFFF,
            'durationMs out of u32 range'),
        assert(sha256.length == digestLen,
            'sha256 must be $digestLen B');

  final Uint8List mediaId;
  final MediaKind kind;
  final int total;
  final int durationMs;
  final String mime;
  final Uint8List sha256;

  static const int version = 0x01;
  static const int idLen = 16;
  static const int digestLen = 32;

  Uint8List encode() {
    final mimeBytes = utf8.encode(mime);
    if (mimeBytes.length > 255) {
      throw const FormatException('mime > 255 UTF-8 bytes');
    }
    final out = Uint8List(
      1 + idLen + 1 + 2 + 4 + 1 + mimeBytes.length + digestLen,
    );
    var c = 0;
    out[c++] = version;
    out.setRange(c, c += idLen, mediaId);
    out[c++] = kind.tag;
    out[c++] = (total >> 8) & 0xff;
    out[c++] = total & 0xff;
    out[c++] = (durationMs >> 24) & 0xff;
    out[c++] = (durationMs >> 16) & 0xff;
    out[c++] = (durationMs >> 8) & 0xff;
    out[c++] = durationMs & 0xff;
    out[c++] = mimeBytes.length;
    out.setRange(c, c += mimeBytes.length, mimeBytes);
    out.setRange(c, c + digestLen, sha256);
    return out;
  }

  static MediaManifest decode(Uint8List bytes) {
    if (bytes.length < 1 + idLen + 1 + 2 + 4 + 1 + digestLen) {
      throw const FormatException('media manifest truncated');
    }
    if (bytes[0] != version) {
      throw FormatException(
          'unknown media manifest version 0x${bytes[0].toRadixString(16)}');
    }
    var c = 1;
    final id = Uint8List.fromList(bytes.sublist(c, c += idLen));
    final kind = MediaKind.fromByte(bytes[c++]);
    final total = (bytes[c] << 8) | bytes[c + 1];
    c += 2;
    final durMs = (bytes[c] << 24) |
        (bytes[c + 1] << 16) |
        (bytes[c + 2] << 8) |
        bytes[c + 3];
    c += 4;
    final mimeLen = bytes[c++];
    if (bytes.length < c + mimeLen + digestLen) {
      throw const FormatException('media manifest mime/sha overrun');
    }
    final mime = utf8.decode(
      bytes.sublist(c, c + mimeLen),
      allowMalformed: true,
    );
    c += mimeLen;
    final sha = Uint8List.fromList(bytes.sublist(c, c + digestLen));
    return MediaManifest(
      mediaId: id,
      kind: kind,
      total: total,
      durationMs: durMs,
      mime: mime,
      sha256: sha,
    );
  }
}

