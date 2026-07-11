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
  mediaManifest(0x50),

  /// Read receipt — acknowledges one or more previously-received messages by
  /// the 16-byte transport msgId they arrived under. Rides the same
  /// sign + encrypt path as text; 1:1 chats only. See [ReadReceipt].
  receipt(0x40),

  /// Emoji reaction to a single message, referenced by its transport msgId.
  /// Same sign + encrypt path as text; works in 1:1 chats and channels.
  /// See [Reaction].
  reaction(0x60),

  /// Invitation handing one peer the key to a shared-key channel, over the
  /// 1:1 signed + SealedBox path. See [ChannelInvite].
  channelInvite(0x70),

  /// New text for a message the sender already sent, referenced by its
  /// transport msgId. See [MessageEdit].
  edit(0x80),

  /// "Delete for everyone" — the sender retracts a message they sent,
  /// referenced by its transport msgId. See [MessageDelete].
  delete(0x90);

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

// ---------------------------------------------------------------------------
// Text length-hiding padding.
//
// A passive BLE sniffer can read the ciphertext length and thereby the exact
// plaintext length of a message — "ok" vs a 40-char sentence are trivially
// distinguishable. We pad *short* text so the common cases all share one
// length. Layout of a padded text body (sits after the 0x10 type tag, inside
// the signed + SealedBox-encrypted payload):
//
//   [realLen : 2 bytes BE][utf8 text : realLen][random pad : 0..N]
//
// Short messages (realLen + 2 <= padBucket) are padded up to `padBucket`
// bytes; everything longer is sent as-is (just the 2-byte prefix) to stay
// inside the BLE MTU budget. The pad is random so it carries no structure;
// it's stripped after signature verification on the receiver.
const int _textPadBucket = 48;
final _padRand = Random.secure();

/// Wrap UTF-8 [text] bytes into a padded, self-describing text body. Pass
/// [bucket] = 0 to add only the length prefix with no padding — used by the
/// forward-secret path, where every extra byte risks overflowing the MTU
/// (length-hiding is sacrificed there in favour of fitting FS into a frame).
Uint8List padTextPayload(Uint8List utf8Text, {int bucket = _textPadBucket}) {
  if (utf8Text.length > 0xFFFF) {
    throw const FormatException('text too long for 16-bit length prefix');
  }
  final base = 2 + utf8Text.length;
  final target = base <= bucket ? bucket : base;
  final out = Uint8List(target);
  out[0] = (utf8Text.length >> 8) & 0xff;
  out[1] = utf8Text.length & 0xff;
  out.setRange(2, 2 + utf8Text.length, utf8Text);
  for (var i = 2 + utf8Text.length; i < target; i++) {
    out[i] = _padRand.nextInt(256);
  }
  return out;
}

/// Recover the original UTF-8 bytes from a padded text body. Tolerates a
/// legacy (pre-padding) body that is just raw UTF-8 with no length prefix —
/// if the declared length overruns the buffer we fall back to returning the
/// whole body, so a peer on an older build still renders (garbled length
/// prefix shows as two extra glyphs, but no crash).
Uint8List unpadTextPayload(Uint8List body) {
  if (body.length < 2) return body;
  final declared = (body[0] << 8) | body[1];
  if (declared > body.length - 2) {
    // Not our padded format (older sender) — treat the whole thing as text.
    return body;
  }
  return Uint8List.fromList(body.sublist(2, 2 + declared));
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
    this.senderIdentityPub,
    this.senderEphemeralPub,
  })  : assert(mediaId.length == idLen, 'mediaId must be $idLen B'),
        assert(total >= 1 && total < 0x10000, 'total out of u16 range'),
        assert(durationMs >= 0 && durationMs <= 0xFFFFFFFF,
            'durationMs out of u32 range'),
        assert(sha256.length == digestLen,
            'sha256 must be $digestLen B'),
        assert(
            (senderIdentityPub == null) == (senderEphemeralPub == null),
            'FS pubkeys come as a pair'),
        assert(senderIdentityPub == null ||
            senderIdentityPub.length == pubLen),
        assert(senderEphemeralPub == null ||
            senderEphemeralPub.length == pubLen);

  final Uint8List mediaId;
  final MediaKind kind;
  final int total;
  final int durationMs;
  final String mime;
  final Uint8List sha256;

  /// Forward-secrecy setup (v0x02). When present, the media chunks are sealed
  /// with a per-transfer X3DH key ([MediaFsCipher]) rather than SealedBox: the
  /// sender's identity + ephemeral X25519 publics let the receiver run the
  /// matching X3DH derivation. Null for a legacy (v0x01) non-FS transfer.
  final Uint8List? senderIdentityPub;
  final Uint8List? senderEphemeralPub;

  static const int versionV1 = 0x01;
  static const int versionV2Fs = 0x02;
  static const int idLen = 16;
  static const int digestLen = 32;
  static const int pubLen = 32;

  /// True when this manifest commits the chunks to the forward-secret path.
  bool get isForwardSecret =>
      senderIdentityPub != null && senderEphemeralPub != null;

  Uint8List encode() {
    final mimeBytes = utf8.encode(mime);
    if (mimeBytes.length > 255) {
      throw const FormatException('mime > 255 UTF-8 bytes');
    }
    final fs = isForwardSecret;
    final out = Uint8List(
      1 + idLen + 1 + 2 + 4 + 1 + mimeBytes.length + digestLen +
          (fs ? pubLen * 2 : 0),
    );
    var c = 0;
    out[c++] = fs ? versionV2Fs : versionV1;
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
    out.setRange(c, c += digestLen, sha256);
    if (fs) {
      out.setRange(c, c += pubLen, senderIdentityPub!);
      out.setRange(c, c += pubLen, senderEphemeralPub!);
    }
    return out;
  }

  static MediaManifest decode(Uint8List bytes) {
    if (bytes.length < 1 + idLen + 1 + 2 + 4 + 1 + digestLen) {
      throw const FormatException('media manifest truncated');
    }
    final ver = bytes[0];
    if (ver != versionV1 && ver != versionV2Fs) {
      throw FormatException(
          'unknown media manifest version 0x${ver.toRadixString(16)}');
    }
    final fs = ver == versionV2Fs;
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
    final trailer = digestLen + (fs ? pubLen * 2 : 0);
    if (bytes.length < c + mimeLen + trailer) {
      throw const FormatException('media manifest mime/sha overrun');
    }
    final mime = utf8.decode(
      bytes.sublist(c, c + mimeLen),
      allowMalformed: true,
    );
    c += mimeLen;
    final sha = Uint8List.fromList(bytes.sublist(c, c += digestLen));
    Uint8List? idPub;
    Uint8List? ephPub;
    if (fs) {
      idPub = Uint8List.fromList(bytes.sublist(c, c += pubLen));
      ephPub = Uint8List.fromList(bytes.sublist(c, c += pubLen));
    }
    return MediaManifest(
      mediaId: id,
      kind: kind,
      total: total,
      durationMs: durMs,
      mime: mime,
      sha256: sha,
      senderIdentityPub: idPub,
      senderEphemeralPub: ephPub,
    );
  }
}

/// Delivery state a [ReadReceipt] can acknowledge. Only [read] is emitted
/// today — plain delivery is already tracked at the BLE-write layer — but the
/// status byte keeps the format open for a future `delivered` receipt without
/// a wire break.
enum ReceiptStatus {
  delivered(0x01),
  read(0x02);

  const ReceiptStatus(this.tag);
  final int tag;

  static ReceiptStatus? fromByte(int b) {
    for (final v in ReceiptStatus.values) {
      if (v.tag == b) return v;
    }
    return null;
  }
}

/// Acknowledgement that the recipient has seen one or more messages, each
/// referenced by the 16-byte transport msgId it was originally sent under
/// (the sender records that id as [Message.wireId]; the receiver copies it
/// from the envelope). Batches several ids into one frame to keep BLE airtime
/// cheap when a chat is opened with a backlog of unread messages.
///
/// Wire layout (inside an [InnerPayloadType.receipt] body):
///
/// ```
///   [status : 1 byte]            ← ReceiptStatus tag
///   [count  : 1 byte]            ← number of acknowledged ids (1..255)
///   [ids    : count * 16 bytes]  ← transport msgIds being acknowledged
/// ```
class ReadReceipt {
  ReadReceipt({required this.status, required this.msgIds})
      : assert(msgIds.length >= 1 && msgIds.length <= 255,
            'receipt must carry 1..255 ids'),
        assert(msgIds.every((id) => id.length == idLen),
            'every msgId must be $idLen B');

  final ReceiptStatus status;
  final List<Uint8List> msgIds;

  static const int idLen = 16;

  /// Max ids that fit one frame while leaving room for the signature +
  /// SealedBox + envelope overhead inside the BLE MTU. 12 * 16 = 192B body.
  static const int maxIdsPerFrame = 12;

  Uint8List encode() {
    final out = Uint8List(2 + msgIds.length * idLen);
    out[0] = status.tag;
    out[1] = msgIds.length;
    var c = 2;
    for (final id in msgIds) {
      out.setRange(c, c += idLen, id);
    }
    return out;
  }

  static ReadReceipt decode(Uint8List bytes) {
    if (bytes.length < 2) {
      throw const FormatException('read receipt truncated');
    }
    final status = ReceiptStatus.fromByte(bytes[0]);
    if (status == null) {
      throw FormatException(
          'unknown receipt status 0x${bytes[0].toRadixString(16)}');
    }
    final count = bytes[1];
    if (bytes.length < 2 + count * idLen) {
      throw const FormatException('read receipt id list overrun');
    }
    final ids = <Uint8List>[];
    var c = 2;
    for (var i = 0; i < count; i++) {
      ids.add(Uint8List.fromList(bytes.sublist(c, c += idLen)));
    }
    return ReadReceipt(status: status, msgIds: ids);
  }
}

/// Emoji reaction to a single message, referenced by its 16-byte transport
/// msgId. An [op] of [ReactionOp.add] attaches the emoji, [ReactionOp.remove]
/// clears a previously-added one (toggle-off).
///
/// Wire layout (inside an [InnerPayloadType.reaction] body):
///
/// ```
///   [op       : 1 byte]            ← ReactionOp tag
///   [emojiLen : 1 byte]
///   [emoji    : emojiLen bytes UTF-8]
///   [targetId : 16 bytes]          ← msgId of the message being reacted to
/// ```
enum ReactionOp {
  remove(0x00),
  add(0x01);

  const ReactionOp(this.tag);
  final int tag;

  static ReactionOp? fromByte(int b) {
    for (final v in ReactionOp.values) {
      if (v.tag == b) return v;
    }
    return null;
  }
}

class Reaction {
  Reaction({required this.op, required this.emoji, required this.targetMsgId})
      : assert(targetMsgId.length == idLen, 'targetMsgId must be $idLen B');

  final ReactionOp op;
  final String emoji;
  final Uint8List targetMsgId;

  static const int idLen = 16;

  Uint8List encode() {
    final emojiBytes = utf8.encode(emoji);
    if (emojiBytes.isEmpty || emojiBytes.length > 255) {
      throw const FormatException('reaction emoji must be 1..255 UTF-8 bytes');
    }
    final out = Uint8List(1 + 1 + emojiBytes.length + idLen);
    var c = 0;
    out[c++] = op.tag;
    out[c++] = emojiBytes.length;
    out.setRange(c, c += emojiBytes.length, emojiBytes);
    out.setRange(c, c += idLen, targetMsgId);
    return out;
  }

  static Reaction decode(Uint8List bytes) {
    if (bytes.length < 2) {
      throw const FormatException('reaction truncated');
    }
    final op = ReactionOp.fromByte(bytes[0]);
    if (op == null) {
      throw FormatException(
          'unknown reaction op 0x${bytes[0].toRadixString(16)}');
    }
    final emojiLen = bytes[1];
    if (bytes.length < 2 + emojiLen + idLen) {
      throw const FormatException('reaction body overrun');
    }
    var c = 2;
    final emoji = utf8.decode(bytes.sublist(c, c + emojiLen),
        allowMalformed: true);
    c += emojiLen;
    final target = Uint8List.fromList(bytes.sublist(c, c + idLen));
    return Reaction(op: op, emoji: emoji, targetMsgId: target);
  }
}

/// Invitation handing one peer the key to a shared-key channel.
///
/// It carries the channel's **derived key**, not its password: the invitee can
/// then read and post without the inviter having to store the human secret or
/// put it on the wire. (A channel's key is all the authority there is —
/// membership *is* holding it.)
///
/// Wire layout (inside an [InnerPayloadType.channelInvite] body, itself inside
/// a SignedPayload + SealedBox addressed to one peer):
///
/// ```
///   [name : N bytes UTF-8 — includes the leading '#']
///   [key  : 32 bytes]
/// ```
///
/// The key is fixed-width and last, so the name needs no length prefix.
///
/// [maxNameBytes] is whatever survives the single-frame BLE budget after every
/// enclosing layer takes its cut — an invite that doesn't fit one write can't
/// be delivered, since nothing below this reassembles fragments:
///
/// ```
///     1   frame type
///  + 33   transport envelope header
///  +  1   cipher tag
///  + 48   SealedBox overhead (ephemeral pubkey + Poly1305 tag)
///  +105   SignedPayload header (marker + ed pubkey + signature + timestamp)
///  +  1   inner-payload type tag
///  + 32   channel key
///  ----
///   221   → the 240-byte conservative frame ceiling leaves 19 for the name
/// ```
class ChannelInvite {
  ChannelInvite({required this.name, required this.key})
      : assert(key.length == keyLen, 'channel key must be $keyLen B');

  /// Normalised channel name, leading `#` included.
  final String name;

  /// The channel's 32-byte ChaCha20-Poly1305 key.
  final Uint8List key;

  static const int keyLen = 32;

  /// Longest channel name (in UTF-8 bytes) that still fits one BLE frame.
  /// Note this is *bytes*, not characters — Cyrillic costs two per letter.
  static const int maxNameBytes = 19;

  Uint8List encode() {
    final nameBytes = utf8.encode(name);
    if (nameBytes.isEmpty) {
      throw const FormatException('channel invite has an empty name');
    }
    if (nameBytes.length > maxNameBytes) {
      throw const FormatException(
          'channel name too long to fit a single BLE frame');
    }
    final out = Uint8List(nameBytes.length + keyLen);
    out.setRange(0, nameBytes.length, nameBytes);
    out.setRange(nameBytes.length, out.length, key);
    return out;
  }

  static ChannelInvite decode(Uint8List bytes) {
    // Strictly greater: a zero-length name is not a channel.
    if (bytes.length <= keyLen) {
      throw const FormatException('channel invite truncated');
    }
    final split = bytes.length - keyLen;
    // Symmetric with encode(): reject a name we could never re-invite anyone
    // with. It also bounds an attacker-supplied string before it reaches the
    // channel store and the chat list.
    if (split > maxNameBytes) {
      throw const FormatException('channel invite name exceeds the cap');
    }
    final name = utf8.decode(bytes.sublist(0, split), allowMalformed: true);
    final key = Uint8List.fromList(bytes.sublist(split));
    return ChannelInvite(name: name, key: key);
  }
}

/// Replacement text for a message the sender already sent, referenced by the
/// 16-byte transport msgId it went out under.
///
/// Wire layout (inside an [InnerPayloadType.edit] body):
///
/// ```
///   [targetId : 16 bytes — msgId of the message being edited]
///   [text     : N bytes UTF-8 — the new body]
/// ```
///
/// The id is fixed-width and first, so the text needs no length prefix: it runs
/// to the end of the payload. Authorship is *not* carried here — the receiver
/// checks that the signer of this frame is the author of the target message,
/// which is the only thing that makes an edit safe to apply.
class MessageEdit {
  MessageEdit({required this.targetMsgId, required this.text})
      : assert(targetMsgId.length == idLen, 'targetMsgId must be $idLen B');

  final Uint8List targetMsgId;
  final String text;

  static const int idLen = 16;

  Uint8List encode() {
    final textBytes = utf8.encode(text);
    if (textBytes.isEmpty) {
      throw const FormatException('message edit has empty text');
    }
    final out = Uint8List(idLen + textBytes.length);
    out.setRange(0, idLen, targetMsgId);
    out.setRange(idLen, out.length, textBytes);
    return out;
  }

  static MessageEdit decode(Uint8List bytes) {
    // Strictly greater: an edit to empty text is a deletion, not an edit, and
    // this format does not carry one.
    if (bytes.length <= idLen) {
      throw const FormatException('message edit truncated');
    }
    return MessageEdit(
      targetMsgId: Uint8List.fromList(bytes.sublist(0, idLen)),
      text: utf8.decode(bytes.sublist(idLen), allowMalformed: true),
    );
  }
}

/// "Delete for everyone" — retracts a message the sender previously sent,
/// referenced by the 16-byte transport msgId. The body is just that id.
class MessageDelete {
  MessageDelete({required this.targetMsgId})
      : assert(targetMsgId.length == idLen, 'targetMsgId must be $idLen B');

  final Uint8List targetMsgId;

  static const int idLen = 16;

  Uint8List encode() => Uint8List.fromList(targetMsgId);

  static MessageDelete decode(Uint8List bytes) {
    if (bytes.length != idLen) {
      throw const FormatException('message delete must be exactly the id');
    }
    return MessageDelete(targetMsgId: Uint8List.fromList(bytes));
  }
}

