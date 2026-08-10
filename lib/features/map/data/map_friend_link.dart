import 'dart:convert';

/// A shareable, human-looking map link carried inside an ordinary chat message.
///
/// The link is never fetched from the internet. It is parsed locally and
/// treated as an in-app action, exactly like shared contacts and locations.
class MapFriendLink {
  const MapFriendLink._({
    required this.kind,
    required this.displayName,
    required this.createdAt,
  });

  final MapFriendLinkKind kind;
  final String displayName;
  final DateTime createdAt;

  static const _prefix = 'https://cubechat.app/map/';

  static MapFriendLink invite({required String displayName}) => MapFriendLink._(
        kind: MapFriendLinkKind.invite,
        displayName: displayName,
        createdAt: DateTime.now(),
      );

  static MapFriendLink accepted({required String displayName}) =>
      MapFriendLink._(
        kind: MapFriendLinkKind.accepted,
        displayName: displayName,
        createdAt: DateTime.now(),
      );

  String encode() {
    final json = jsonEncode(<String, String>{
      'v': '1',
      'k': kind.name,
      'n': displayName,
      't': createdAt.toUtc().toIso8601String(),
    });
    final payload = base64Url.encode(utf8.encode(json)).replaceAll('=', '');
    return '$_prefix$payload';
  }

  static MapFriendLink? tryParse(String raw) {
    final text = raw.trim();
    if (!text.startsWith(_prefix)) return null;
    try {
      var b64 = text.substring(_prefix.length);
      b64 = b64.padRight((b64.length + 3) ~/ 4 * 4, '=');
      final map =
          (jsonDecode(utf8.decode(base64Url.decode(b64))) as Map).cast<String, dynamic>();
      if (map['v'] != '1') return null;
      final kind = switch (map['k']) {
        'invite' => MapFriendLinkKind.invite,
        'accepted' => MapFriendLinkKind.accepted,
        _ => null,
      };
      final displayName = (map['n'] as String?)?.trim() ?? '';
      if (kind == null || displayName.isEmpty) return null;
      final createdAt =
          DateTime.tryParse(map['t'] as String? ?? '')?.toLocal() ??
              DateTime.now();
      return MapFriendLink._(
        kind: kind,
        displayName: displayName,
        createdAt: createdAt,
      );
    } catch (_) {
      return null;
    }
  }
}

enum MapFriendLinkKind { invite, accepted }
