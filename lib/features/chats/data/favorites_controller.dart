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
class FavoritesController extends Notifier<Set<String>> {
  static const _key = 'favorite_chats';

  // The settings box is shared with the nickname / background-mode controllers,
  // so it must be opened as Box<dynamic> — Hive forbids two type parameters for
  // one box.
  Box<dynamic>? _box;

  @override
  Set<String> build() {
    unawaited(_load());
    return const <String>{};
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final raw = box.get(_key);
      if (raw is List) {
        final loaded = raw.whereType<String>().toSet();
        if (loaded.isNotEmpty) state = loaded;
      }
    } catch (e) {
      debugPrint('FavoritesController load failed: $e');
    }
  }

  bool isFavorite(String chatId) => state.contains(chatId);

  Future<void> toggle(String chatId) async {
    final next = {...state};
    // Set.remove reports whether it was there, so one call decides the branch.
    if (!next.remove(chatId)) next.add(chatId);
    state = next;
    await _persist();
  }

  /// Drop a chat from favourites — used when the chat itself is deleted.
  Future<void> forget(String chatId) async {
    if (!state.contains(chatId)) return;
    state = {...state}..remove(chatId);
    await _persist();
  }

  /// Used by Emergency Wipe.
  Future<void> clear() async {
    state = const <String>{};
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('FavoritesController clear failed: $e');
    }
  }

  Future<void> _persist() async {
    try {
      await _box?.put(_key, state.toList());
    } catch (e) {
      debugPrint('FavoritesController persist failed: $e');
    }
  }
}

final favoritesControllerProvider =
    NotifierProvider<FavoritesController, Set<String>>(FavoritesController.new);
