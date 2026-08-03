import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// Chats the user has opened *from search*, newest first.
///
/// Deliberately its own list rather than a read of the existing read markers.
/// Those record when each chat was last opened, which would give a plausible
/// "recent" ordering for free — but it would be the wrong list (every chat you
/// open, not the ones you went looking for) and, worse, the "Clear" button
/// beside it would have to either lie or wipe state the unread badges depend
/// on. A separate list makes clearing mean exactly what it says.
///
/// Ids are the same ones the chat list keys on: a peer's pubkey-hex or a
/// `#channel` name.
class RecentSearchesController extends Notifier<List<String>> {
  static const _key = 'recent_search_chats';

  /// Kept short on purpose: this is a shortcut back to someone you just looked
  /// up, not a history. Past a handful it stops being scannable and starts
  /// being a second, worse chat list.
  static const int maxEntries = 12;

  // Shared settings box — see FavoritesController for why it must be dynamic.
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
        final loaded = raw.whereType<String>().take(maxEntries).toList();
        if (loaded.isNotEmpty) state = loaded;
      }
    } catch (e) {
      debugPrint('RecentSearches load failed: $e');
    }
  }

  /// Move [chatId] to the front. Re-opening something already in the list
  /// promotes it rather than duplicating it, so the list stays a set ordered by
  /// recency.
  Future<void> remember(String chatId) async {
    if (chatId.isEmpty) return;
    final next = [chatId, ...state.where((id) => id != chatId)];
    state = next.length > maxEntries ? next.sublist(0, maxEntries) : next;
    await _persist();
  }

  /// Drop one entry — the per-row dismiss.
  Future<void> forget(String chatId) async {
    if (!state.contains(chatId)) return;
    state = state.where((id) => id != chatId).toList();
    await _persist();
  }

  /// The "Clear" action, and Emergency Wipe.
  Future<void> clear() async {
    state = const <String>[];
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('RecentSearches clear failed: $e');
    }
  }

  Future<void> _persist() async {
    try {
      await _box?.put(_key, state);
    } catch (e) {
      debugPrint('RecentSearches persist failed: $e');
    }
  }
}

final recentSearchesControllerProvider =
    NotifierProvider<RecentSearchesController, List<String>>(
  RecentSearchesController.new,
);
