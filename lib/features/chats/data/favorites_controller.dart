import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// Chat ids the user has starred, by the same id the chat list keys on: a
/// peer's pubkey-hex, or a `#channel` name.
///
/// Kept in the shared settings box rather than on [KnownPeer] / [Channel]:
/// favouriting is a purely local preference and applies to both kinds of chat,
/// so it has no business travelling with a peer's identity record.
///
/// **Ordered**, and that is the whole reason this is a list rather than the set
/// it used to be. Favourites float above everything else in the chat list, and
/// inside that group they were sorted by recency like any other chat — so the
/// person you star *because* you want them first moved around anyway, every
/// time somebody else wrote. The order here is the user's own, set by dragging,
/// and a newly starred chat goes to the top because that is where you were
/// looking when you starred it.
class FavoritesController extends Notifier<List<String>> {
  static const _key = 'favorite_chats';

  // The settings box is shared with the nickname / background-mode controllers,
  // so it must be opened as Box<dynamic> — Hive forbids two type parameters for
  // one box.
  Box<dynamic>? _box;

  @override
  List<String> build() {
    unawaited(_load());
    return const <String>[];
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final raw = box.get(_key);
      if (raw is List) {
        // Written as a list either way — the set version persisted
        // `state.toList()` — so history from before ordering existed reads back
        // unchanged, in whatever order Hive happens to hand it over. That is
        // the honest migration: nobody chose an order before now, so there is
        // none to preserve, and the first drag establishes one.
        final loaded = raw.whereType<String>().toList();
        // A duplicate would give ReorderableListView two children with the same
        // key, which is a crash rather than a cosmetic problem.
        final seen = <String>{};
        final unique = [
          for (final id in loaded)
            if (seen.add(id)) id,
        ];
        if (unique.isNotEmpty) state = unique;
      }
    } catch (e) {
      debugPrint('FavoritesController load failed: $e');
    }
  }

  bool isFavorite(String chatId) => state.contains(chatId);

  /// Where [chatId] sits in the user's order, or -1 when it is not starred.
  int rankOf(String chatId) => state.indexOf(chatId);

  Future<void> toggle(String chatId) async {
    final next = [...state];
    // Newly starred goes first: starring is a statement that this one matters
    // more than the others, and burying it at the bottom of the group would
    // make the user drag it up immediately.
    if (!next.remove(chatId)) next.insert(0, chatId);
    state = next;
    await _persist();
  }

  /// Move the favourite at [oldIndex] to [newIndex], as a drag ends.
  Future<void> reorder(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= state.length) return;
    final next = [...state];
    final id = next.removeAt(oldIndex);
    // ReorderableListView reports the destination as an index into the list
    // *before* the removal, so dragging downward is one too many.
    final target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    next.insert(target.clamp(0, next.length), id);
    state = next;
    await _persist();
  }

  /// Drop a chat from favourites — used when the chat itself is deleted.
  Future<void> forget(String chatId) async {
    if (!state.contains(chatId)) return;
    state = [...state]..remove(chatId);
    await _persist();
  }

  /// Used by Emergency Wipe.
  Future<void> clear() async {
    state = const <String>[];
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('FavoritesController clear failed: $e');
    }
  }

  Future<void> _persist() async {
    try {
      await _box?.put(_key, [...state]);
    } catch (e) {
      debugPrint('FavoritesController persist failed: $e');
    }
  }
}

final favoritesControllerProvider =
    NotifierProvider<FavoritesController, List<String>>(
        FavoritesController.new);
