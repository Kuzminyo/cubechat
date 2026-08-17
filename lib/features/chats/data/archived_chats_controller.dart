import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// Conversations put out of the way without being got rid of.
///
/// The list already had two ways for a chat to leave it and neither was this
/// one. A pin holds a chat at the top; [HiddenChatsController] suppresses a row
/// whose history was deleted and brings it back the moment anybody speaks. What
/// was missing is the ordinary case — a chat that is still live, still wanted,
/// and simply not what you want to look at every time you open the app.
///
/// So: its own drawer, one row at the top of the list, and the chats inside it
/// keep working. Unlike hiding, an archived chat does **not** come back on its
/// own when a message arrives; that would make archiving useless for the exact
/// conversations people archive. It comes back when the user says so.
class ArchivedChatsController extends Notifier<Set<String>> {
  static const _key = 'archived_chats';

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
      debugPrint('ArchivedChatsController load failed: $e');
    }
  }

  bool isArchived(String chatId) => state.contains(chatId);

  Future<void> archive(String chatId) async {
    if (state.contains(chatId)) return;
    state = {...state, chatId};
    await _persist();
  }

  Future<void> unarchive(String chatId) async {
    if (!state.contains(chatId)) return;
    state = {...state}..remove(chatId);
    await _persist();
  }

  /// Flip it, and answer where the chat ended up — the swipe action needs to
  /// know which way it went to say so.
  Future<bool> toggle(String chatId) async {
    final archived = !state.contains(chatId);
    if (archived) {
      await archive(chatId);
    } else {
      await unarchive(chatId);
    }
    return archived;
  }

  /// Used by Emergency Wipe.
  Future<void> clear() async {
    state = const <String>{};
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('ArchivedChatsController clear failed: $e');
    }
  }

  Future<void> _persist() async {
    try {
      await _box?.put(_key, state.toList());
    } catch (e) {
      debugPrint('ArchivedChatsController persist failed: $e');
    }
  }
}

final archivedChatsControllerProvider =
    NotifierProvider<ArchivedChatsController, Set<String>>(
  ArchivedChatsController.new,
);
