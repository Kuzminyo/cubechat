import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../chat/data/messages_controller.dart';
import '../../chat/models/message.dart';
import 'map_friend_link.dart';

class MapFriendsController extends Notifier<Set<String>> {
  static const _key = 'map.friends';

  Box<dynamic>? _box;

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
    if (chatId.startsWith('#') || state.contains(chatId)) return;
    state = {...state, chatId};
    await _persist();
  }

  Future<void> forget(String chatId) async {
    if (!state.contains(chatId)) return;
    state = {...state}..remove(chatId);
    await _persist();
  }

  void _mergeAcceptedLinks(Map<String, List<Message>> history) {
    final next = {...state};
    for (final entry in history.entries) {
      final chatId = entry.key;
      if (chatId.startsWith('#')) continue;
      if (_hasAcceptedLink(entry.value)) next.add(chatId);
    }
    if (setEquals(next, state)) return;
    state = next;
    unawaited(_persist());
  }

  bool _hasAcceptedLink(List<Message> messages) {
    for (final message in messages.reversed) {
      if (message.kind != MessageKind.text) continue;
      final link = MapFriendLink.tryParse(message.text);
      if (link?.kind == MapFriendLinkKind.accepted) {
        return true;
      }
    }
    return false;
  }

  Future<void> _persist() async {
    try {
      await _box?.put(_key, state.toList()..sort());
    } catch (e) {
      debugPrint('MapFriendsController persist failed: $e');
    }
  }

  Future<void> clear() async {
    state = const <String>{};
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('MapFriendsController clear failed: $e');
    }
  }
}

final mapFriendsControllerProvider =
    NotifierProvider<MapFriendsController, Set<String>>(
  MapFriendsController.new,
);
