import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../chats/data/saved_messages.dart';
import '../../chats/models/chat.dart';

/// A chat offered in the system share sheet's top row.
@immutable
class DirectShareTarget {
  const DirectShareTarget({required this.id, required this.name});

  final String id;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is DirectShareTarget && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// Four, as many as most share sheets have room for.
const int directShareLimit = 4;

/// The chats to offer, in the order the list shows them. People only: a room
/// cannot take a file, so a tile for one would promise what the share cannot do.
/// [chats] is already without the archive and without strangers' requests —
/// what the person put away or has not accepted does not appear in a system
/// sheet either.
List<DirectShareTarget> pickDirectShareTargets(List<Chat> chats) => [
      for (final chat in chats)
        if (!chat.isChannel &&
            !isSavedChat(chat.id) &&
            chat.peerName.trim().isNotEmpty)
          DirectShareTarget(id: chat.id, name: chat.peerName.trim()),
    ].take(directShareLimit).toList();

/// The chat a tapped tile named, or null when it is gone or is not a person —
/// the caller then shows the ordinary picker instead.
Chat? chatForDirectShare(List<Chat> chats, String? id) {
  if (id == null) return null;
  for (final chat in chats) {
    if (chat.id == id && !chat.isChannel) return chat;
  }
  return null;
}

/// Android's Direct Share. See `DirectShareTargets.kt`.
abstract final class DirectShare {
  static const MethodChannel _channel = MethodChannel('cubechat/share');

  static List<DirectShareTarget>? _published;

  /// Hands [targets] to the platform, unless it already has exactly these.
  static Future<void> publish(List<DirectShareTarget> targets) async {
    if (kIsWeb || !Platform.isAndroid) return;
    if (listEquals(_published, targets)) return;
    try {
      await _channel.invokeMethod<Object?>('publishTargets', {
        'targets': [
          for (final target in targets) {'id': target.id, 'name': target.name},
        ],
      });
      _published = targets;
    } catch (_) {
      // Nothing to tell the person: the share sheet just has no tiles.
    }
  }
}
