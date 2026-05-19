import 'dart:math';
import 'dart:typed_data';

/// Mesh-relay envelope around transport payloads.
///
/// Layout on the wire (inside a [FrameType.transport] frame's payload):
///
/// ```
///   [origin pubkey hash : 8 bytes]
///   [dest   pubkey hash : 8 bytes]   ← all zeros means broadcast
///   [message id          : 16 bytes UUID v4]
///   [ttl                 : 1 byte]
///   [body                : N bytes]   ← Noise- or SealedBox-encrypted payload
/// ```
///
/// `originPubkeyHash` and `destPubkeyHash` are the first 8 bytes of
/// `BLAKE2s(static_pubkey)`. That's enough collision resistance for
/// routing decisions (2^64 buckets — far more than any plausible mesh
/// participant count) and keeps the per-frame overhead inside the BLE
/// MTU budget.
///
/// `ttl` (default 7, max-hops in bitchat-style mesh) is decremented by
/// every forwarding relay; when it hits 0 the frame is dropped. Direct-
/// link chats can either set ttl=1 (no forwarding) or rely on the
/// dedup cache to swallow loops.
class TransportEnvelope {
  TransportEnvelope({
    required this.originPubkeyHash,
    required this.destPubkeyHash,
    required this.msgId,
    required this.ttl,
    required this.body,
  })  : assert(originPubkeyHash.length == hashLen, 'origin hash must be $hashLen B'),
        assert(destPubkeyHash.length == hashLen, 'dest hash must be $hashLen B'),
        assert(msgId.length == msgIdLen, 'msgId must be $msgIdLen B'),
        assert(ttl >= 0 && ttl <= 255, 'ttl out of byte range');

  /// First 8 bytes of BLAKE2s(static pubkey) — collision-resistant peer id
  /// stable across BLE Privacy address rotation.
  final Uint8List originPubkeyHash;

  /// Destination hash. All-zeros = broadcast (every peer that receives this
  /// frame should treat it as addressed to them).
  final Uint8List destPubkeyHash;

  /// 16-byte random message id. Combined with [originPubkeyHash], gives a
  /// unique-per-frame key for the dedup cache.
  final Uint8List msgId;

  /// Hops remaining. Set to a default at the sender (7), each relay
  /// decrements before re-emitting.
  final int ttl;

  /// Payload. Currently Noise-encrypted (direct link); switches to
  /// SealedBox in M3.D so relays can forward without decrypting.
  final Uint8List body;

  static const int hashLen = 8;
  static const int msgIdLen = 16;
  static const int headerLen = hashLen + hashLen + msgIdLen + 1;

  /// Default TTL for sender-originated frames. Matches bitchat's mesh
  /// max-hops; experimentally sufficient for typical event-scale crowds.
  static const int defaultTtl = 7;

  /// All-zeros destination = broadcast (treat as addressed to me).
  static Uint8List broadcastDest() => Uint8List(hashLen);

  bool get isBroadcast {
    for (final b in destPubkeyHash) {
      if (b != 0) return false;
    }
    return true;
  }

  Uint8List encode() {
    final out = Uint8List(headerLen + body.length);
    var cursor = 0;
    out.setRange(cursor, cursor += hashLen, originPubkeyHash);
    out.setRange(cursor, cursor += hashLen, destPubkeyHash);
    out.setRange(cursor, cursor += msgIdLen, msgId);
    out[cursor++] = ttl;
    out.setRange(cursor, cursor + body.length, body);
    return out;
  }

  static TransportEnvelope decode(Uint8List bytes) {
    if (bytes.length < headerLen) {
      throw const FormatException('transport envelope shorter than header');
    }
    var cursor = 0;
    final origin = Uint8List.fromList(bytes.sublist(cursor, cursor += hashLen));
    final dest = Uint8List.fromList(bytes.sublist(cursor, cursor += hashLen));
    final id = Uint8List.fromList(bytes.sublist(cursor, cursor += msgIdLen));
    final ttl = bytes[cursor++];
    final body = Uint8List.fromList(bytes.sublist(cursor));
    return TransportEnvelope(
      originPubkeyHash: origin,
      destPubkeyHash: dest,
      msgId: id,
      ttl: ttl,
      body: body,
    );
  }

  /// Returns the envelope with [ttl] decremented by one (or zero if already
  /// at zero). Used by relays before forwarding.
  TransportEnvelope decrementTtl() {
    return TransportEnvelope(
      originPubkeyHash: originPubkeyHash,
      destPubkeyHash: destPubkeyHash,
      msgId: msgId,
      ttl: ttl > 0 ? ttl - 1 : 0,
      body: body,
    );
  }

  // ----- helpers -----

  static final _random = Random.secure();

  /// Mints a fresh random 16-byte message id.
  static Uint8List newMsgId() {
    final out = Uint8List(msgIdLen);
    for (var i = 0; i < out.length; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }

  /// First 8 bytes of [fullPubkey] hashed — used as the routing-level
  /// identity. Pure utility; the actual hash lives in
  /// MessagingService where the BLAKE2s API is async.
  static Uint8List shortHashFromHashBytes(Uint8List hashBytes) {
    return Uint8List.fromList(hashBytes.sublist(0, hashLen));
  }

  /// Convenience: print msgId as hex for log lines.
  String msgIdHex() {
    final sb = StringBuffer();
    for (final b in msgId) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Convenience: print a pubkey-hash as short hex.
  static String hashHex(Uint8List h) {
    final sb = StringBuffer();
    for (final b in h) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
