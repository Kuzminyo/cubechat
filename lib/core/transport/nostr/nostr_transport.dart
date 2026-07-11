import 'dart:async';
import 'dart:typed_data';

import 'nostr_event.dart';
import 'nostr_frame_codec.dart';

/// cubechat's custom event kind for a frame-carrying direct message. Sits in
/// the NIP-17 "regular DM" range but is cubechat-specific; the payload is our
/// own encrypted frame (see [NostrFrameCodec]), not a NIP-04/44 message.
const int kCubechatFrameKind = 1059;

/// Tag name for the recipient's Nostr pubkey (standard NIP-01 `"p"` tag). The
/// relay indexes on it so a receiver can subscribe to just their own mail.
const String kRecipientTag = 'p';

/// The network seam: publishes signed events to relays and streams back events
/// addressed to us. A production implementation manages a pool of relay
/// WebSocket connections (`wss://…`), REQ/EVENT/EOSE framing, and reconnection.
/// Tests supply an in-memory fake so the whole [NostrTransport] flow is
/// exercised without a socket.
abstract class NostrRelayClient {
  /// Publish a fully-signed [event] to the connected relays.
  Future<void> publish(NostrEvent event);

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
  Future<void> sendFrame({
    required String recipientNpubHex,
    required Uint8List frameBytes,
  }) async {
    final event = NostrEvent(
      pubkey: _signer.npubHex,
      createdAt: _clock().millisecondsSinceEpoch ~/ 1000,
      kind: kCubechatFrameKind,
      tags: [
        [kRecipientTag, recipientNpubHex],
      ],
      content: NostrFrameCodec.encodeContent(frameBytes),
    );
    final signed = await _signer.sign(event);
    await _relay.publish(signed);
  }

  /// Frames addressed to us, recovered from inbound Nostr events. Events whose
  /// content isn't a cubechat frame are silently skipped (a shared public relay
  /// carries unrelated traffic).
  Stream<Uint8List> inboundFrames() {
    return _relay
        .subscribe(recipientPubkeyHex: _signer.npubHex)
        .map((e) => NostrFrameCodec.decodeContent(e.content))
        .where((bytes) => bytes != null)
        .cast<Uint8List>();
  }
}
