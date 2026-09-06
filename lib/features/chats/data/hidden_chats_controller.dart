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
  Future<void>? _loading;

  /// A write that arrived before there was a box to put it in. See [_persist].
  bool _writePending = false;

  /// Resolves when what is hidden on disk is in [state].
  ///
  /// [_load] already merges rather than assigns, which is half of the race
  /// described there. This is the other half: the write needs the box, and
  /// until this resolves there is not one.
  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  Set<String> build() {
    unawaited(_loading = _load());
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
        // Merged under whatever is already here, never assigned over it.
        //
        // This runs from `build`, so it is a write that lands at an unknown
        // moment — after an encrypted box has been opened, which is not fast
        // at a cold start. Anything hidden before it finished used to be
        // discarded by it, and the next `hide` then persisted the set without
        // it: a chat deleted early in a session came back, permanently, with
        // nothing to say why.
        //
        // In-memory wins because it is newer by definition: it is the thing
        // the user did during this run.
        if (loaded.isNotEmpty) state = {...loaded, ...state};
      }
    } catch (e) {
      debugPrint('HiddenChatsController load failed: $e');
    }
    // The other half of the same race: the merge above kept the early `hide`,
    // and this is what finally puts it on disk. See [_persist].
    if (_writePending && _box != null) {
      _writePending = false;
      await _persist();
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
    // The merge in [_load] kept the early `hide` in memory; this is what gets
    // it onto disk. Without it, `_box` is still null and `?.put` is a silent
    // no-op — the set was right until the process ended. Waiting for the load
    // instead would block a caller that awaits a hide on a box opened over
    // platform channels, which deadlocks a widget test.
    final box = _box;
    if (box == null) {
      _writePending = true;
      return;
    }
    try {
      await box.put(_key, state.toList());
    } catch (e) {
      debugPrint('HiddenChatsController persist failed: $e');
    }
  }
}

final hiddenChatsControllerProvider =
    NotifierProvider<HiddenChatsController, Set<String>>(
  HiddenChatsController.new,
);
