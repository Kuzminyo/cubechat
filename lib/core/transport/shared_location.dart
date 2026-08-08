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
/// Format: `cubechat:loc:v1:<base64url of "lat,lon,accuracy,expiresAtIso">`.
/// Anything malformed parses as null and stays a plain line of text, which is
/// also what an older build will show — an unknown scheme rather than an empty
/// bubble.
class SharedLocation {
  const SharedLocation({
    required this.latitude,
    required this.longitude,
    this.accuracyMetres = 0,
    this.expiresAt,
  });

  final double latitude;
  final double longitude;
  final int accuracyMetres;

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

  String encode() {
    final payload = [
      latitude.toStringAsFixed(6),
      longitude.toStringAsFixed(6),
      accuracyMetres.toString(),
      expiresAt?.toUtc().toIso8601String() ?? '',
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
      return SharedLocation(
        latitude: lat,
        longitude: lon,
        accuracyMetres: int.tryParse(parts[2]) ?? 0,
        expiresAt: expiry?.toLocal(),
      );
    } catch (_) {
      return null;
    }
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
