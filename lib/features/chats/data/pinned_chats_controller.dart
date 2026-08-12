import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// Chat ids explicitly pinned to the top of the chat list.
///
/// Separate from favourites on purpose: a star is a mark, a pin is placement.
/// Only this list is allowed to float rows above recency sorting.
class PinnedChatsController extends Notifier<List<String>> {
  static const _key = 'pinned_chats';

  Box<dynamic>? _box;

  @override
  List<String> build() {
    unawaited(_load());
    return const <String>[];
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider.openEncryptedBox<dynamic>(
        HiveBoxes.settings,
      );
      _box = box;
      final raw = box.get(_key);
      if (raw is! List) return;
      final seen = <String>{};
      final loaded = [
        for (final id in raw.whereType<String>())
          if (seen.add(id)) id,
      ];
      if (loaded.isNotEmpty) state = loaded;
    } catch (e) {
      debugPrint('PinnedChats load failed: $e');
    }
  }

  bool isPinned(String chatId) => state.contains(chatId);

  int rankOf(String chatId) => state.indexOf(chatId);

  Future<void> pin(String chatId) async {
    if (state.contains(chatId)) return;
    state = [chatId, ...state];
    await _persist();
  }

  Future<void> unpin(String chatId) async {
    if (!state.contains(chatId)) return;
    state = [...state]..remove(chatId);
    await _persist();
  }

  Future<void> toggle(String chatId) =>
      state.contains(chatId) ? unpin(chatId) : pin(chatId);

  Future<void> forget(String chatId) => unpin(chatId);

  Future<void> clear() async {
    state = const <String>[];
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('PinnedChats clear failed: $e');
    }
  }

  Future<void> _persist() async {
    try {
      await _box?.put(_key, [...state]);
    } catch (e) {
      debugPrint('PinnedChats persist failed: $e');
    }
  }
}

final pinnedChatsControllerProvider =
    NotifierProvider<PinnedChatsController, List<String>>(
  PinnedChatsController.new,
);
