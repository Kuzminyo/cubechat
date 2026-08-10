import 'dart:convert';

/// A position, shared into a conversation as an ordinary text message.
///
/// The same trick [SharedContact] uses, and for the same reason: a location is
/// a handful of numbers, and giving it its own payload type would mean teaching
/// every path that carries a message — the 1:1 send with its sessions and
/// forward secrecy, the channel broadcast, store-and-forward, the relay,
/// replies, forwarding — about one more kind of thing. Riding inside text costs
/// a URI's worth of bytes and inherits all of that for free, already encrypted
/// and already signed, because it *is* a message.
///
/// Format: `cubechat:loc:v1:<base64url of "lat,lon,accuracy,expiresAtIso[,p]">`.
/// Anything malformed parses as null and stays a plain line of text, which is
/// also what an older build will show — an unknown scheme rather than an empty
/// bubble.
///
/// The trailing `p` marks a *map presence beacon* rather than a position a
/// person chose to send. The distinction matters because the two are nothing
/// alike in volume: a shared location is one deliberate message, while the map
/// heartbeat emits one every 45 seconds to every map friend for as long as the
/// screen is open. Carried as a fifth field precisely so an older build ignores
/// it and still renders the pin it already knows how to render.
///
/// An `x` in that slot is a beacon that also says "take me off the map". An
/// older build reads neither letter, sees a position that expired the moment it
/// was sent, and removes the pin — which is exactly what `x` asks for.
class SharedLocation {
  const SharedLocation({
    required this.latitude,
    required this.longitude,
    this.accuracyMetres = 0,
    this.expiresAt,
    this.presence = false,
    this.retract = false,
  });

  final double latitude;
  final double longitude;
  final int accuracyMetres;

  /// True when this came from the map's background heartbeat, false when a
  /// person pressed "share my location" in a conversation.
  ///
  /// A beacon is transport, not conversation: it never becomes a bubble, is
  /// never stored in history, and is never acknowledged with a read receipt.
  final bool presence;

  /// The sender is asking to be removed from the map, right now.
  ///
  /// Stated rather than inferred. Withdrawal used to travel as nothing but an
  /// already-expired beacon, which is indistinguishable from an ordinary beacon
  /// the relay held onto and replayed an hour later — and the receiver could
  /// only guess, so a backlog of stale heartbeats wiped every pin on the map.
  final bool retract;

  /// When the sender said this stops being worth showing, or null for "no
  /// expiry stated".
  ///
  /// A statement of intent, not an enforcement: the recipient has the numbers
  /// and could keep them, exactly as they could screenshot a photo. What it
  /// buys is that the app stops presenting a stale position as current, which
  /// is the difference between "here I am" and "here is where I live".
  final DateTime? expiresAt;

  static const _prefix = 'cubechat:loc:v1:';

  bool get expired => expiresAt != null && DateTime.now().isAfter(expiresAt!);

  /// This beacon means "take me off the map", not "here is where I last was".
  ///
  /// The coordinate check keeps faith with builds that predate [retract]: their
  /// withdrawal is an expired beacon at exactly (0, 0), which is the sentinel
  /// `MapPresenceController.withdraw` has always sent and which no fix ever
  /// reports.
  bool get retraction =>
      retract || (expired && latitude == 0 && longitude == 0);

  String encode() {
    final payload = [
      latitude.toStringAsFixed(6),
      longitude.toStringAsFixed(6),
      accuracyMetres.toString(),
      expiresAt?.toUtc().toIso8601String() ?? '',
      if (retract) 'x' else if (presence) 'p',
    ].join(',');
    return '$_prefix${base64Url.encode(utf8.encode(payload)).replaceAll('=', '')}';
  }

  static SharedLocation? tryParse(String raw) {
    final text = raw.trim();
    if (!text.startsWith(_prefix)) return null;
    try {
      var b64 = text.substring(_prefix.length);
      // base64url without padding, restored — the encoder strips it so the URI
      // has no '=' in it.
      b64 = b64.padRight((b64.length + 3) ~/ 4 * 4, '=');
      final parts = utf8.decode(base64Url.decode(b64)).split(',');
      if (parts.length < 3) return null;
      final lat = double.tryParse(parts[0]);
      final lon = double.tryParse(parts[1]);
      // A pin somewhere impossible is a broken or hostile sender, and it must
      // not reach a maps URL.
      if (lat == null || lon == null) return null;
      if (lat.isNaN || lon.isNaN) return null;
      if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
      final expiry = parts.length > 3 && parts[3].isNotEmpty
          ? DateTime.tryParse(parts[3])
          : null;
      final flag = parts.length > 4 ? parts[4] : '';
      return SharedLocation(
        latitude: lat,
        longitude: lon,
        accuracyMetres: int.tryParse(parts[2]) ?? 0,
        expiresAt: expiry?.toLocal(),
        presence: flag == 'p' || flag == 'x',
        retract: flag == 'x',
      );
    } catch (_) {
      return null;
    }
  }

  /// How far [expiresAt] may sit from the moment a message was sent before it
  /// stops looking like the map's two-minute heartbeat.
  ///
  /// Nothing a *person* sends can land inside it: the share sheet offers no
  /// expiry at all, fifteen minutes, or an hour, and the nearest of those is
  /// three times this.
  static const _beaconWindow = Duration(minutes: 5);

  /// Is this line of text a map beacon rather than something a person sent?
  ///
  /// [sentAt] is what makes it work for beacons that carry no flag: everything
  /// an older build emitted, and everything already sitting in history from
  /// before the flag existed. The map heartbeat is the only thing that ever
  /// asked for a two-minute window.
  ///
  /// The comparison has an upper bound and no lower one: a window that closes
  /// within five minutes of the send is a beacon, and so is one that closed
  /// before the message even arrived. It used to be symmetric — five minutes
  /// *either* side — which quietly meant "arrived promptly", and that is the one
  /// thing an inbound beacon cannot promise. `sentAt` is the moment of receipt,
  /// and the Nostr relay replays its backlog on every reconnect, so the beacons
  /// piled up while the app slept all came back at once, hours past their
  /// expiry, missed the window from below, and landed in the conversation as
  /// bubbles — a burst of base64 URIs on every wake, which is exactly what this
  /// is here to prevent.
  ///
  /// Nothing a person sends is caught by the loosened end: the share sheet
  /// offers no expiry, fifteen minutes, or an hour, so a deliberate share only
  /// falls inside the window once it is already ten minutes stale — by which
  /// point its own sender has said it is no longer worth showing.
  static bool isBeaconText(String raw, DateTime sentAt) {
    final parsed = tryParse(raw);
    if (parsed == null) return false;
    if (parsed.presence) return true;
    final expiry = parsed.expiresAt;
    if (expiry == null) return false;
    return expiry.difference(sentAt) <= _beaconWindow;
  }

  /// A `geo:` URI, which every mobile platform resolves to whatever maps app
  /// the user actually chose.
  ///
  /// No tiles are fetched here, deliberately. Drawing a map in-app means asking
  /// a tile server for the square somebody is standing in — handing their
  /// position to a third party, which is the one thing this app exists not to
  /// do. Opening the phone's own maps app moves that choice to where the user
  /// already made it.
  Uri get geoUri => Uri.parse(
        'geo:$latitude,$longitude?q=$latitude,$longitude',
      );
}
