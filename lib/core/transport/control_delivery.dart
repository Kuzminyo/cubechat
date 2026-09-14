import 'package:flutter/foundation.dart';

import 'nostr/nostr_transport.dart';

/// How much is known about a frame once the transports have been handed it.
///
/// Three facts, not two, and the middle one is the reason this exists. A call
/// on mobile internet (callId 9ba4922a, 2026-09-14) published its invite to
/// seven relays and heard no `OK` from any of them inside the two-second
/// deadline. That was reported as zero links, the call failed as unavailable,
/// and the other phone — which had received the invite 290 ms after it left
/// and was already ringing — got a hangup a second later. The `OK`s and the
/// ringing acknowledgement arrived together, three seconds late, in one burst:
/// the caller's downlink had stalled, not its uplink. Silence from a relay says
/// nothing about whether the event was stored.
enum DeliveryCertainty {
  /// Nothing left this phone: no key, no route, no connected relay, every write
  /// failed, or every relay that answered said no.
  notSent,

  /// Written somewhere — a relay socket that has not answered yet, or the mesh
  /// on a link that is not the recipient's own — and not confirmed.
  unconfirmed,

  /// A relay answered `OK true`, or the recipient's own link took the write.
  confirmed,
}

/// What one control frame did: how many roads carried it and how sure that is.
@immutable
class ControlDelivery {
  const ControlDelivery({required this.links, required this.certainty});

  /// Roads that took the frame: Bluetooth writes plus a relay that confirmed.
  /// The same number the int-returning senders have always reported.
  final int links;

  final DeliveryCertainty certainty;

  static const notSent =
      ControlDelivery(links: 0, certainty: DeliveryCertainty.notSent);

  bool get isNotSent => certainty == DeliveryCertainty.notSent;

  @override
  String toString() => '$links link(s), ${certainty.name}';

  @override
  bool operator ==(Object other) =>
      other is ControlDelivery &&
      other.links == links &&
      other.certainty == certainty;

  @override
  int get hashCode => Object.hash(links, certainty);
}

/// What a relay publish established, before anything else is known.
enum RelayPublishOutcome {
  /// The fallback is off, there is no npub, no relay is connected, or the
  /// publish threw before a write.
  unavailable,

  /// Every relay the event was written to answered no.
  refused,

  /// Written, and nobody said yes inside the deadline.
  unconfirmed,

  /// At least one relay said yes.
  accepted;

  /// Read a receipt without the generosity `isRefused` has.
  ///
  /// `PublishReceipt.isRefused` is true as soon as one relay says no and none
  /// has said yes, even while the others are still silent — right for a text
  /// message that is held and sent again, wrong for a call, where a silent
  /// relay may already have delivered the invite. Only a refusal from every
  /// relay written to is a refusal here.
  static RelayPublishOutcome fromReceipt(PublishReceipt receipt) {
    if (receipt.isAccepted) return accepted;
    if (receipt.sentTo <= 0) return unavailable;
    if (receipt.rejected >= receipt.sentTo) return refused;
    return unconfirmed;
  }
}

/// Combine what the mesh and the relay each did into one [ControlDelivery].
///
/// [meshLinks] counts Bluetooth writes. [direct] says one of them was the
/// recipient's own session, which is as good as a relay's `OK`; a fan-out onto
/// somebody else's link is only a hope that the mesh knows a route.
ControlDelivery combineControlDelivery({
  required int meshLinks,
  required bool direct,
  required RelayPublishOutcome relay,
}) {
  final relayLinks = relay == RelayPublishOutcome.accepted ? 1 : 0;
  final links = meshLinks + relayLinks;
  if ((meshLinks > 0 && direct) || relay == RelayPublishOutcome.accepted) {
    return ControlDelivery(links: links, certainty: DeliveryCertainty.confirmed);
  }
  if (meshLinks > 0 || relay == RelayPublishOutcome.unconfirmed) {
    return ControlDelivery(
      links: links,
      certainty: DeliveryCertainty.unconfirmed,
    );
  }
  return ControlDelivery.notSent;
}
