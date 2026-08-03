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
  })  : assert(originPubkeyHash.length == hashLen,
            'origin hash must be $hashLen B'),
        assert(
            destPubkeyHash.length == hashLen, 'dest hash must be $hashLen B'),
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

  /// Hop budget for a sparse mesh — the full depth. Matches bitchat's mesh
  /// max-hops; experimentally sufficient for typical event-scale crowds.
  static const int defaultTtl = 7;

  /// Hop budget once this node is well connected. See [ttlForLinkCount].
  static const int denseTtl = 5;

  // New clients stamp the initial hop budget into the otherwise-random
  // message id. This keeps the wire header compatible with old clients while
  // letting the receiver calculate the actual route length.
  static const int _routeMarker0 = 0xca;
  static const int _routeMarker1 = 0x7e;

  /// Initial hop budget recorded by the sender, or null for legacy frames.
  int? get initialTtl {
    if (msgId[0] != _routeMarker0 || msgId[1] != _routeMarker1) return null;
    final value = msgId[2];
    return value > 0 && value <= defaultTtl ? value : null;
  }

  /// Number of radio links crossed before reaching this receiver.
  int? get traversedHops {
    final initial = initialTtl;
    if (initial == null || ttl > initial) return null;
    return initial - ttl + 1;
  }

  /// Link count at which a node counts as sitting in a dense mesh.
  static const int denseLinkThreshold = 6;

  /// How many hops to spend on a frame we're putting on the mesh, given how
  /// many links *this* node currently holds.
  ///
  /// A flood costs roughly `fanout ^ hops`, so the two terms have to be traded
  /// against each other rather than fixed independently. With one or two links
  /// the mesh is a chain: each hop advances the frame by one peer and the full
  /// depth is what makes a distant node reachable at all. With six or more the
  /// topology is a cluster — every extra hop multiplies the number of copies in
  /// flight while adding almost no reach, because in a dense graph nearly
  /// everyone is already a few hops away. That is where a fixed 7 stops buying
  /// delivery and starts buying duplicate airtime, which on BLE is also battery.
  ///
  /// So the budget is cut exactly where the amplification is worst. The trade
  /// is real and deliberate: a node deep in a crowd will no longer reach a peer
  /// more than five hops out. In the topology that triggers the cut, a peer that
  /// far away is rare — and the store-and-forward buffer plus the internet
  /// fallback both remain as backstops for one that isn't.
  static int ttlForLinkCount(int links) =>
      links >= denseLinkThreshold ? denseTtl : defaultTtl;

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
  TransportEnvelope decrementTtl() => withTtl(ttl > 0 ? ttl - 1 : 0);

  /// Same envelope with a different hop budget. Used by a relay to apply its
  /// own density ceiling on top of the decrement.
  TransportEnvelope withTtl(int newTtl) {
    return TransportEnvelope(
      originPubkeyHash: originPubkeyHash,
      destPubkeyHash: destPubkeyHash,
      msgId: msgId,
      ttl: newTtl,
      body: body,
    );
  }

  // ----- helpers -----

  static final _random = Random.secure();

  /// Mints a fresh random 16-byte message id. When [initialTtl] is supplied,
  /// embeds it in a legacy-safe prefix so receivers can show the real hops.
  static Uint8List newMsgId({int? initialTtl}) {
    final out = Uint8List(msgIdLen);
    for (var i = 0; i < out.length; i++) {
      out[i] = _random.nextInt(256);
    }
    if (initialTtl != null) {
      if (initialTtl <= 0 || initialTtl > defaultTtl) {
        throw ArgumentError.value(initialTtl, 'initialTtl');
      }
      out[0] = _routeMarker0;
      out[1] = _routeMarker1;
      out[2] = initialTtl;
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
