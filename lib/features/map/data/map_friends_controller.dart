import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../chat/data/messages_controller.dart';
import '../../chat/models/message.dart';
import 'map_friend_link.dart';

/// Whether this conversation says the two of you are on each other's maps.
///
/// An acceptance counts from either side — it is one message, and both ends
/// hold it. An invitation counts only when *we* sent it: offering somebody your
/// map is the act of sharing it, whereas being offered one is not yet an answer
/// and must stay the invitee's to give.
bool chatIsMapFriend(List<Message> messages) {
  for (final message in messages.reversed) {
    if (message.kind != MessageKind.text) continue;
    final link = MapFriendLink.tryParse(message.text);
    if (link == null) continue;
    if (link.kind == MapFriendLinkKind.accepted) return true;
    if (link.kind == MapFriendLinkKind.invite && message.isMine) return true;
  }
  return false;
}

class MapFriendsController extends Notifier<Set<String>> {
  static const _key = 'map.friends';

  /// Ids the user has taken *off* the map, kept so [_mergeAcceptedLinks] does
  /// not put them straight back.
  ///
  /// The merge reads the conversation, and the conversation is permanent: the
  /// invitation and the acceptance are still sitting in it after somebody is
  /// removed, so without this the next message of any kind re-derived them as a
  /// map friend and the remove button did nothing that survived a minute.
  static const _dismissedKey = 'map.friends.dismissed';

  Box<dynamic>? _box;
  Set<String> _dismissed = const <String>{};

  @override
  Set<String> build() {
    ref.listen<Map<String, List<Message>>>(
      messagesControllerProvider,
      (_, next) => _mergeAcceptedLinks(next),
    );
    unawaited(_load());
    return const <String>{};
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final raw = box.get(_key);
      final loaded = <String>{
        if (raw is List)
          for (final value in raw)
            if (value is String && value.isNotEmpty) value,
      };
      final dismissed = box.get(_dismissedKey);
      _dismissed = <String>{
        if (dismissed is List)
          for (final value in dismissed)
            if (value is String && value.isNotEmpty) value,
      };
      if (loaded.isNotEmpty) {
        state = {...state, ...loaded};
      }
      _mergeAcceptedLinks(ref.read(messagesControllerProvider));
    } catch (e) {
      debugPrint('MapFriendsController load failed: $e');
    }
  }

  bool contains(String chatId) => state.contains(chatId);

  Future<void> activate(String chatId) async {
    if (chatId.startsWith('#')) return;
    final undismissed = _dismissed.contains(chatId);
    if (state.contains(chatId) && !undismissed) return;
    if (undismissed) _dismissed = {..._dismissed}..remove(chatId);
    state = {...state, chatId};
    await _persist();
  }

  Future<void> forget(String chatId) async {
    _dismissed = {..._dismissed, chatId};
    if (!state.contains(chatId)) {
      await _persist();
      return;
    }
    state = {...state}..remove(chatId);
    await _persist();
  }

  /// Derive map friends from what the conversations already say.
  ///
  /// Two things count, and the second is what makes the pairing hold together:
  ///
  ///   * an acceptance, from either side — the invitee taps it, and both ends
  ///     see the same message land in the same conversation;
  ///   * an invitation *we sent*. Inviting somebody to your map is the act of
  ///     sharing it with them, so the sender is a map friend from that moment
  ///     rather than from the moment the reply gets through.
  ///
  /// Waiting for the reply is what left the two phones disagreeing: the
  /// invitee accepted and had the sender on their map at once, while the
  /// sender's side depended on an acceptance message surviving the trip — and
  /// when it did not (peer out of range, relay backlog, app killed mid-send)
  /// the invitation looked ignored and had to be sent all over again, from the
  /// other direction.
  void _mergeAcceptedLinks(Map<String, List<Message>> history) {
    final next = {...state};
    for (final entry in history.entries) {
      final chatId = entry.key;
      if (chatId.startsWith('#') || _dismissed.contains(chatId)) continue;
      if (chatIsMapFriend(entry.value)) next.add(chatId);
    }
    if (setEquals(next, state)) return;
    state = next;
    unawaited(_persist());
  }

  Future<void> _persist() async {
    try {
      await _box?.put(_key, state.toList()..sort());
      await _box?.put(_dismissedKey, _dismissed.toList()..sort());
    } catch (e) {
      debugPrint('MapFriendsController persist failed: $e');
    }
  }

  Future<void> clear() async {
    state = const <String>{};
    _dismissed = const <String>{};
    try {
      await _box?.delete(_key);
      await _box?.delete(_dismissedKey);
    } catch (e) {
      debugPrint('MapFriendsController clear failed: $e');
    }
  }
}

final mapFriendsControllerProvider =
    NotifierProvider<MapFriendsController, Set<String>>(
  MapFriendsController.new,
);
