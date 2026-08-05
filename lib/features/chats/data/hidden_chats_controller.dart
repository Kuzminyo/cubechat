import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// Chats the user deleted, keyed the way the chat list keys chats.
///
/// Deleting a conversation used to *forget the person*: the roster entry went
/// with it, along with their keys, their prekey and their npub — so the contact
/// vanished from Contacts and could not be written to again without swapping
/// codes a second time. That is a heavy price for clearing a conversation, and
/// nobody asks for it when they tap delete.
///
/// The reason it was done is that the chat list is built *from* the roster, so
/// a peer who still exists still produces a tile. This is the missing third
/// state: the contact stays, the history is gone, and the tile is suppressed
/// for exactly as long as there is nothing in it. The first new message in
/// either direction brings it back on its own — see the filter in
/// `chatsProvider` — so nothing has to remember to un-hide it.
class HiddenChatsController extends Notifier<Set<String>> {
  static const _key = 'hidden_chats';

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
      debugPrint('HiddenChatsController load failed: $e');
    }
  }

  bool isHidden(String chatId) => state.contains(chatId);

  Future<void> hide(String chatId) async {
    if (state.contains(chatId)) return;
    state = {...state, chatId};
    await _persist();
  }

  /// Explicitly bring one back — the chat was opened again from Contacts.
  Future<void> unhide(String chatId) async {
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
      debugPrint('HiddenChatsController clear failed: $e');
    }
  }

  Future<void> _persist() async {
    try {
      await _box?.put(_key, state.toList());
    } catch (e) {
      debugPrint('HiddenChatsController persist failed: $e');
    }
  }
}

final hiddenChatsControllerProvider =
    NotifierProvider<HiddenChatsController, Set<String>>(
  HiddenChatsController.new,
);
