import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../models/chat.dart';
import 'saved_messages.dart';

/// A way of narrowing the chat list. Not a place chats are *put*: nothing is
/// moved, nothing has to be filed, and a chat that stops being unread leaves
/// the Unread folder on its own.
enum ChatFolder {
  unread,
  direct,
  channels,
  favorites,
  online;

  static ChatFolder? byName(String? name) {
    for (final folder in ChatFolder.values) {
      if (folder.name == name) return folder;
    }
    return null;
  }

  bool matches(Chat chat) => switch (this) {
        ChatFolder.unread => chat.unreadCount > 0,
        // Saved notes are neither a person nor a room, so they belong to
        // neither folder — filing your own notebook under "people you talk to"
        // is how a folder starts lying about what it holds.
        ChatFolder.direct => !chat.isChannel && !isSavedChat(chat.id),
        ChatFolder.channels => chat.isChannel,
        ChatFolder.favorites => chat.isFavorite,
        ChatFolder.online => chat.isOnline || chat.isReachableViaMesh,
      };
}

/// Which folders the chat list offers, in the order they appear.
///
/// Empty by default, and that is the point. The list used to ship with four
/// filter pills above it whether or not anyone wanted them — a permanent row of
/// chrome between the search field and the first conversation, on the screen
/// that opens the app. Someone with six chats has nothing to filter; someone
/// with a hundred wants their own cut, not ours. So the row exists only once
/// something has been added to it.
class ChatFoldersController extends Notifier<List<ChatFolder>> {
  static const _key = 'chats.folders';

  Box<dynamic>? _box;

  @override
  List<ChatFolder> build() {
    unawaited(_load());
    return const <ChatFolder>[];
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider.openEncryptedBox<dynamic>(
        HiveBoxes.settings,
      );
      _box = box;
      final raw = box.get(_key);
      if (raw is! List) return;
      final loaded = raw
          .whereType<String>()
          .map(ChatFolder.byName)
          .whereType<ChatFolder>()
          .toList();
      if (loaded.isNotEmpty) state = loaded;
    } catch (e) {
      debugPrint('ChatFolders load failed: $e');
    }
  }

  bool isOn(ChatFolder folder) => state.contains(folder);

  /// Add or remove [folder], keeping the declared enum order rather than the
  /// order they were switched on in — the row should look the same to everyone
  /// who chose the same folders.
  Future<void> toggle(ChatFolder folder) async {
    final next = state.contains(folder)
        ? state.where((f) => f != folder).toList()
        : (ChatFolder.values.where((f) => f == folder || state.contains(f)))
            .toList();
    state = next;
    await _persist();
  }

  /// Emergency Wipe: back to a list with no chrome on it.
  Future<void> clear() async {
    state = const <ChatFolder>[];
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('ChatFolders clear failed: $e');
    }
  }

  Future<void> _persist() async {
    try {
      await _box?.put(_key, [for (final folder in state) folder.name]);
    } catch (e) {
      debugPrint('ChatFolders persist failed: $e');
    }
  }
}

final chatFoldersControllerProvider =
    NotifierProvider<ChatFoldersController, List<ChatFolder>>(
  ChatFoldersController.new,
);

/// Which folder the list is currently showing; null is everything.
///
/// Not persisted: a filter you cannot see the edge of is a bug report waiting
/// to happen ("my chats are gone"), and it should not survive a relaunch.
final selectedFolderProvider = StateProvider<ChatFolder?>((_) => null);
