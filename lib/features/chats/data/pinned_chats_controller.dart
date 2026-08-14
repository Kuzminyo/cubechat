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

  /// Rewrite the order of [ids] among the pins, leaving every other pin in the
  /// slot it already holds.
  ///
  /// The list somebody drags in can be a subset of this one — a search, a
  /// folder, a chat whose history was deleted — and a drag there says nothing
  /// about the pins it is not showing. Taking the slots the visible ids occupy
  /// and refilling them in the new order moves exactly what was moved: the
  /// obvious `[...dragged, ...rest]` would quietly demote every pin the filter
  /// happened to hide.
  Future<void> reorderVisible(List<String> ids) async {
    if (ids.length < 2) return;
    final wanted = ids.toSet();
    final slots = <int>[
      for (var i = 0; i < state.length; i++)
        if (wanted.contains(state[i])) i,
    ];
    // The caller's idea of what is pinned can be a beat behind ours — the list
    // it dragged in was built from the state before the *last* drag landed.
    // This used to refuse the whole move on any mismatch, which is the "every
    // other drag does nothing" that got reported: the second drag in a row
    // arrived with one stale id and was thrown away entire. Reorder what we
    // can recognise instead, in the order asked for; an id we have no slot for
    // simply is not ours to place.
    final known = [
      for (final id in ids)
        if (state.contains(id)) id,
    ];
    if (known.length < 2) return;
    ids = known;
    final next = [...state];
    for (var i = 0; i < slots.length; i++) {
      next[slots[i]] = ids[i];
    }
    if (listEquals(next, state)) return;
    state = next;
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
