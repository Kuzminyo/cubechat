import 'dart:convert';

import '../../crypto/signature_worker.dart';
import 'nostr_event.dart';
import 'nostr_transport.dart';

/// Message framing for the Nostr relay protocol (NIP-01) plus the inbound-event
/// verification cubechat requires before trusting a frame off a public relay.
///
/// This is the pure, socket-free core of a relay client: it turns intent into
/// the JSON arrays a relay speaks and parses the JSON arrays it sends back. The
/// actual `wss://` transport (a `WebSocketNostrRelayClient` over
/// `web_socket_channel`) is a thin wrapper that pipes strings through these
/// functions and gates every inbound event on [verifyInboundEvent].
class NostrRelayProtocol {
  NostrRelayProtocol._();

  // --------------------------- client → relay ---------------------------

  /// A `["REQ", subId, filter]` subscribing to cubechat frame events addressed
  /// to [recipientPubkeyHex]. [since] (unix seconds) lets a reconnecting client
  /// skip events it already processed.
  static String req(
    String subId, {
    required String recipientPubkeyHex,
    int? since,
  }) {
    final filter = <String, dynamic>{
      'kinds': [kCubechatFrameKind],
      '#p': [recipientPubkeyHex],
      if (since != null) 'since': since,
    };
    return jsonEncode(['REQ', subId, filter]);
  }

  /// A `["EVENT", event]` publishing a signed event.
  static String event(NostrEvent event) {
    return jsonEncode(['EVENT', event.toJson()]);
  }

  /// A `["CLOSE", subId]` tearing down a subscription.
  static String close(String subId) => jsonEncode(['CLOSE', subId]);

  // --------------------------- relay → client ---------------------------

  /// Parse one relay→client message. Never throws — anything malformed or
  /// unrecognised comes back as [RelayUnknown].
  static RelayMessage parse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List || decoded.isEmpty) return RelayUnknown(raw);
      switch (decoded[0]) {
        case 'EVENT':
          if (decoded.length < 3 || decoded[2] is! Map) {
            return RelayUnknown(raw);
          }
          return RelayEvent(
            decoded[1] as String,
            NostrEvent.fromJson((decoded[2] as Map).cast<String, dynamic>()),
          );
        case 'EOSE':
          if (decoded.length < 2) return RelayUnknown(raw);
          return RelayEose(decoded[1] as String);
        case 'OK':
          if (decoded.length < 3) return RelayUnknown(raw);
          return RelayOk(
            decoded[1] as String,
            decoded[2] as bool,
            decoded.length > 3 ? decoded[3] as String : '',
          );
        case 'AUTH':
          if (decoded.length != 2 || decoded[1] is! String) {
            return RelayUnknown(raw);
          }
          return RelayAuth(decoded[1] as String);
        case 'CLOSED':
          if (decoded.length < 3) return RelayUnknown(raw);
          return RelayClosed(decoded[1] as String, decoded[2] as String);
        case 'NOTICE':
          if (decoded.length < 2) return RelayUnknown(raw);
          return RelayNotice(decoded[1] as String);
        default:
          return RelayUnknown(raw);
      }
    } catch (_) {
      return RelayUnknown(raw);
    }
  }

  // ----------------------------- verification ----------------------------

  /// True iff [event] is a well-formed, correctly-signed cubechat frame event.
  /// A relay client MUST pass every inbound event through this before acting on
  /// it — a public relay is untrusted and can hand back anything.
  ///
  /// Checks, in order: the cubechat kind, a present id + sig, that the id
  /// actually hashes the event fields, and that the BIP-340 Schnorr signature
  /// verifies against the event's own pubkey.
  static Future<bool> verifyInboundEvent(NostrEvent event) async {
    if (event.kind != kCubechatFrameKind) return false;
    final id = event.id;
    final sig = event.sig;
    if (id == null || sig == null) return false;
    if (id.length != 64 || sig.length != 128 || event.pubkey.length != 64) {
      return false;
    }
    // Both checks in one crossing to another isolate.
    //
    // They used to run here, on the thread that draws. Measured on a phone
    // receiving a circle: just under four milliseconds of *synchronous* Dart
    // per event, and a file is one event per chunk — hundreds in a row, none
    // of them yielding, because a BIP-340 scalar multiplication in Dart has no
    // suspension point in it. See [SignatureWorker] for where they went and
    // what happens on a phone that cannot spawn an isolate.
    return SignatureWorker.instance.verifyEvent(
      serialized: event.serializeForId(),
      idHex: id,
      pubkeyHex: event.pubkey,
      sigHex: sig,
    );
  }

}

/// A parsed relay→client message.
sealed class RelayMessage {
  const RelayMessage();
}

/// `["EVENT", subId, event]` — an event matching one of our subscriptions.
class RelayEvent extends RelayMessage {
  const RelayEvent(this.subscriptionId, this.event);
  final String subscriptionId;
  final NostrEvent event;
}

/// `["EOSE", subId]` — end of stored events; the relay is now live-streaming.
class RelayEose extends RelayMessage {
  const RelayEose(this.subscriptionId);
  final String subscriptionId;
}

/// `["OK", eventId, accepted, message]` — a publish ack/nack.
class RelayOk extends RelayMessage {
  const RelayOk(this.eventId, this.accepted, this.message);
  final String eventId;
  final bool accepted;
  final String message;
}

/// `["NOTICE", message]` — a human-readable relay notice.
class RelayNotice extends RelayMessage {
  const RelayNotice(this.message);
  final String message;
}

/// Anything malformed or of a type we don't handle.
class RelayUnknown extends RelayMessage {
  const RelayUnknown(this.raw);
  final String raw;
}

/// NIP-42 challenge: reply on this connection, never publish as an EVENT.
class RelayAuth extends RelayMessage {
  const RelayAuth(this.challenge);
  final String challenge;
}

/// A socket can be connected while its subscription has been refused.
class RelayClosed extends RelayMessage {
  const RelayClosed(this.subscriptionId, this.message);
  final String subscriptionId;
  final String message;
}
