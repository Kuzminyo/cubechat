import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../util/cost_meter.dart';
import 'nostr_event.dart';
import 'nostr_frame_codec.dart';

/// One inbound frame, and when the sender said they sent it.
///
/// `sentAt` comes off the Nostr event's `created_at`, which the sender chooses
/// — so it is a claim, not a measurement. Treat it as an upper bound on
/// freshness and never as proof of recency: clamp it to now before using it,
/// or a peer could keep themselves permanently "just seen" by dating a beacon
/// in the future.
@immutable
class InboundFrame {
  const InboundFrame({required this.bytes, required this.sentAt});

  final Uint8List bytes;
  final DateTime sentAt;
}

/// cubechat's custom event kind for a frame-carrying direct message. Sits in
/// the NIP-17 "regular DM" range but is cubechat-specific; the payload is our
/// own encrypted frame (see [NostrFrameCodec]), not a NIP-04/44 message.
const int kCubechatFrameKind = 1059;

/// Tag name for the recipient's Nostr pubkey (standard NIP-01 `"p"` tag). The
/// relay indexes on it so a receiver can subscribe to just their own mail.
const String kRecipientTag = 'p';

/// Marks a frame worth waking a sleeping phone for.
///
/// The push service cannot decrypt anything — that is the point of it — so it
/// woke a phone for *every* frame addressed to it. Most frames are housekeeping:
/// a presence heartbeat every 70 seconds, read receipts, announcements, typing
/// notices. The result was a "New message" banner about once a minute with no
/// message behind it, which is worse than no notification at all, because it
/// trains the owner to ignore the real ones.
///
/// Only the sender knows which is which, so the sender says so, out here in the
/// clear where the service can read it without holding a key.
///
/// The cost, stated plainly: a relay operator can now tell a real message from
/// housekeeping. That is a genuine leak and it is close to free anyway — a
/// 190-byte event arriving every 70 seconds is a heartbeat to anyone watching
/// sizes and timing, with or without this tag. What stays hidden is what it
/// says, who wrote it, and what the two of you talk about.
///
/// Absent means "do not wake", so an old build simply rings no doorbell rather
/// than ringing it wrongly.
const String kWakeTag = 'w';

/// The network seam: publishes signed events to relays and streams back events
/// addressed to us. A production implementation manages a pool of relay
/// WebSocket connections (`wss://…`), REQ/EVENT/EOSE framing, and reconnection.
/// Tests supply an in-memory fake so the whole [NostrTransport] flow is
/// exercised without a socket.
/// What the relays actually did with an event we published.
///
/// Writing to a socket is not delivery. A relay answers every `EVENT` with an
/// `["OK", <id>, <accepted>, <message>]`, and it says false more often than you
/// would hope — rate limits ("you are noting too much"), size caps, spam
/// heuristics, paid-relay policies. Treating a successful write as a send meant
/// a message could vanish with the app showing it delivered, and it is why this
/// exists: anything downstream that acts on "the message got out" — a push
/// wake, a delivery tick — has to key off acceptance, not off bytes leaving.
@immutable
class PublishReceipt {
  const PublishReceipt({
    required this.sentTo,
    required this.accepted,
    required this.rejected,
    this.rejections = const [],
  });

  /// Relays the event was written to.
  final int sentTo;

  /// Relays that answered `OK true`.
  final int accepted;

  /// Relays that answered `OK false`.
  final int rejected;

  /// Why the rejections happened, for diagnostics.
  final List<String> rejections;

  /// Relays that never answered before the deadline. Silence is not consent,
  /// but it is not a refusal either — the event may well be stored.
  int get silent => (sentTo - accepted - rejected).clamp(0, sentTo);

  /// At least one relay took it. One is enough: the recipient subscribes to
  /// every relay in their own list and de-duplicates by event id.
  bool get isAccepted => accepted > 0;

  /// Nothing accepted it and at least one actively refused — worth surfacing,
  /// as against a timeout where the event probably landed.
  bool get isRefused => accepted == 0 && rejected > 0;

  static const none = PublishReceipt(sentTo: 0, accepted: 0, rejected: 0);

  /// Reads as a verdict, so it has to be one.
  ///
  /// This printed `sent: 3, ok: 1, no: 0, silent: 2` on 304 of 310 publishes
  /// in a shipped log, and that reads as two thirds of the relays being dead.
  /// They are not. `_PendingPublish.record` settles the moment the first `OK`
  /// arrives — deliberately, because waiting for the slowest relay was paid
  /// once per chunk of every file — so the other two were never given a
  /// chance to answer and their silence says nothing whatsoever about them.
  ///
  /// An hour went into being suspicious of healthy relays on the strength of
  /// this line. A count nobody finished collecting should not be printed as
  /// though it were.
  @override
  String toString() {
    final heard = accepted + rejected;
    // Every relay spoke: the numbers mean what they look like.
    if (heard >= sentTo) {
      return 'PublishReceipt(sent: $sentTo, ok: $accepted, no: $rejected)';
    }
    // Stopped early on the first acceptance. The rest are unasked, not silent.
    if (accepted > 0) {
      return 'PublishReceipt(sent: $sentTo, ok: $accepted '
          '(stopped at the first, ${sentTo - heard} not waited for))';
    }
    // Nobody answered inside the deadline. This one really is silence.
    return 'PublishReceipt(sent: $sentTo, no answer from ${sentTo - heard} '
        'in time${rejected > 0 ? ', no: $rejected' : ''})';
  }
}

/// Which set of relays a publish belongs on.
///
/// Public relays rate-limit **per connection**, and they do it bluntly: a burst
/// earns a throttle that lands on everything else in the same burst. Two kinds
/// of traffic here are bursty or relentless, and neither is conversation:
///
///   * [media] — one publish per chunk ([kRelayMediaChunkData], 63 KiB), so a
///     video is dozens of events in a few seconds;
///   * [location] — a map beacon per friend, for ever. A 72-minute field log
///     had **191 of 274 publishes** be map beacons: 70% of everything the
///     radio did, to carry 55 kB.
///
/// Splitting them off keeps a throttle earned by a photo or a pin away from
/// the relay carrying somebody's sentence.
///
/// Every lane's relays are **subscribed to** regardless. Nostr delivery is
/// publish-here-subscribe-here, so a chunk written to a relay the recipient
/// does not read never arrives; the lane decides only which sockets a publish
/// is written to.
enum RelayLane { conversation, media, location }

abstract class NostrRelayClient {
  /// Publish a fully-signed [event] and report what the relays said.
  ///
  /// Resolves once every relay has answered or the implementation's deadline
  /// passes, whichever comes first — never hangs on a relay that goes quiet.
  /// [lane] says which set of relays this belongs on — see [RelayLane]. A pool
  /// with no relays configured for that lane is free to ignore it.
  Future<PublishReceipt> publish(
    NostrEvent event, {
    RelayLane lane = RelayLane.conversation,
  });

  /// Stream of inbound events whose recipient (`"p"`) tag equals
  /// [recipientPubkeyHex]. The relay/client is responsible for filtering by
  /// kind ([kCubechatFrameKind]) and for verifying each event's Schnorr
  /// signature before emitting it.
  Stream<NostrEvent> subscribe({required String recipientPubkeyHex});
}

/// The crypto seam: turns cubechat's identity into a Nostr identity and signs
/// events. Requires **secp256k1 + BIP-340 Schnorr**, which the app's
/// `cryptography` dependency (Ed25519 / X25519) does not provide — hence the
/// interface. The production implementation is [Secp256k1NostrSigner], backed
/// by a pure-Dart BIP-340 signer validated against the official test vectors.
///
/// ## Key-derivation contract
///
/// Each cubechat identity derives one *stable* secp256k1 keypair so a peer can
/// be addressed at a fixed Nostr pubkey across sessions and devices that share
/// the identity seed:
///
/// ```
///   sk_scalar = HKDF-SHA256(
///       ikm  = ed25519_identity_seed,
///       salt = "",
///       info = "cubechat/nostr-secp256k1/v1",
///       len  = 32) mod n     // n = secp256k1 group order
///   // (re-hash with a counter on the negligible-probability zero/overflow)
///   npub = x-only(sk_scalar · G)
/// ```
///
/// The resulting [npubHex] is advertised inside the signed peer announcement
/// (alongside the existing signed prekey) so peers learn where to reach each
/// other off-mesh. Because the derivation is deterministic and seeded by the
/// long-term identity, no extra key material has to be persisted.
abstract class NostrEventSigner {
  /// This identity's 32-byte x-only secp256k1 public key, lowercase hex.
  String get npubHex;

  /// Populate [event.id] + [event.sig] (Schnorr over the id). The event's
  /// [NostrEvent.pubkey] must already equal [npubHex].
  Future<NostrEvent> sign(NostrEvent event);
}

/// Composes a [NostrEventSigner] and a [NostrRelayClient] into the interface
/// [MessagingService] talks to: send a cubechat frame to a peer's Nostr pubkey
/// when the mesh can't reach them, and receive frames the mesh missed.
///
/// It is deliberately symmetric with the BLE path — [sendFrame] takes the same
/// encoded [Frame] bytes that go over a BLE write, and [inboundFrames] yields
/// the same bytes a BLE notify would, so the caller can feed them straight
/// back into its existing `_handleInboundBytes` dispatch.
class NostrTransport {
  NostrTransport({
    required NostrEventSigner signer,
    required NostrRelayClient relay,
    DateTime Function()? clock,
  })  : _signer = signer,
        _relay = relay,
        _clock = clock ?? DateTime.now;

  final NostrEventSigner _signer;
  final NostrRelayClient _relay;
  final DateTime Function() _clock;

  /// Our own Nostr pubkey (hex) — the address peers reach us at.
  String get npubHex => _signer.npubHex;

  /// Build, sign and publish an event carrying [frameBytes] to the peer whose
  /// Nostr pubkey is [recipientNpubHex].
  /// [wakesPeer] marks this as something a person would want to be woken for —
  /// a message, not machinery. Defaults to false so anything added later has to
  /// say it out loud rather than inheriting a doorbell it does not need. See
  /// [kWakeTag].
  /// [lane] keeps a burst off the relays carrying conversation. Nothing about
  /// the event changes — same kind, same tags, same signature — only which
  /// sockets it is written to.
  Future<PublishReceipt> sendFrame({
    required String recipientNpubHex,
    required Uint8List frameBytes,
    bool wakesPeer = false,
    RelayLane lane = RelayLane.conversation,
  }) async {
    final event = NostrEvent(
      pubkey: _signer.npubHex,
      createdAt: _clock().millisecondsSinceEpoch ~/ 1000,
      kind: kCubechatFrameKind,
      tags: [
        [kRecipientTag, recipientNpubHex],
        if (wakesPeer) [kWakeTag, '1'],
      ],
      content: NostrFrameCodec.encodeContent(frameBytes),
    );
    // Timed because it is pure Dart on the UI isolate and there is a lot of it.
    // Every frame that leaves over the internet is one SHA-256 of the event
    // plus one BIP-340 signature, and `Secp256k1.sign` checks its own output,
    // so a publish is a sign and a verify. See [CostMeter] for the measurement
    // that made this worth counting.
    final signed = await CostMeter.instance.measure(
      'nostr-sign',
      () => _signer.sign(event),
    );
    final receipt = await _relay.publish(signed, lane: lane);
    // **A frame that rings a doorbell goes on the conversation lane as well.**
    //
    // The push service watches a fixed list of public relays and knows nothing
    // about lanes. Conversation traffic goes to relays on that list, so a text
    // message wakes a sleeping phone; a media manifest goes to the media lane —
    // our own relay and two others, none of them watched — so the one frame of
    // a transfer that carries the wake tag was published where nothing was
    // listening for it. Reported as circles arriving with no notification,
    // which is exactly what that is: the file lands, and nobody is told.
    //
    // The same signed event, so this costs one more write and no second
    // signature, and the recipient drops the duplicate on event id. One frame
    // per transfer, not per chunk — the media lane exists to keep a burst of
    // chunks off the conversation relays, and a manifest is not a burst.
    //
    // Fixing it here rather than by adding the media relays to the push
    // service's environment: that list is on a server, this one is in the app,
    // and a doorbell that only rings while two lists agree is a doorbell that
    // stops working the next time either changes.
    if (wakesPeer && lane != RelayLane.conversation) {
      try {
        await _relay.publish(signed, lane: RelayLane.conversation);
      } catch (_) {
        // The transfer itself already published successfully; a doorbell that
        // could not be rung is not a reason to fail the file behind it.
      }
    }
    return receipt;
  }

  /// Frames addressed to us, each with the moment its sender stamped it.
  ///
  /// Events whose content isn't a cubechat frame are silently skipped (a shared
  /// public relay carries unrelated traffic).
  ///
  /// The timestamp is the point of this method. A relay *stores* events and
  /// hands them over on the next subscription, so a frame can arrive hours
  /// after it was written — and anything in it that is a claim about a moment
  /// has to be read against when it was said, not when it turned up. A presence
  /// beacon is exactly that: the last one a phone sent before its battery died
  /// sat on a relay saying "I am in the app", and every fresh subscription
  /// delivered it as news.
  Stream<InboundFrame> inboundFramesTimed() {
    return _relay
        .subscribe(recipientPubkeyHex: _signer.npubHex)
        .map((e) {
          final bytes = NostrFrameCodec.decodeContent(e.content);
          return bytes == null
              ? null
              : InboundFrame(
                  bytes: bytes,
                  sentAt: DateTime.fromMillisecondsSinceEpoch(
                    e.createdAt * 1000,
                  ),
                );
        })
        .where((frame) => frame != null)
        .cast<InboundFrame>();
  }

  /// The same stream for callers with nothing to date: the frame bytes alone.
  Stream<Uint8List> inboundFrames() =>
      inboundFramesTimed().map((frame) => frame.bytes);
}
