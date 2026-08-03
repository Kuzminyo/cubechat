import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// The emoji offered on the reaction strip, newest use first.
///
/// The strip used to be six emoji fixed in the source, which is fine right up
/// until the one you actually use isn't among them. Now the whole keyboard is
/// reachable through the picker and this list is what you land on: the six you
/// reacted with most recently, so the strip converges on each person's own
/// habits instead of on someone else's guess at them.
///
/// [defaults] is what a fresh install starts with — the same six as before, so
/// nothing looks like it moved until the user makes it move. The heart leads
/// because the head of this list is also what a double-tap leaves, and that
/// was a heart long before the list existed.
class ReactionEmojiController extends Notifier<List<String>> {
  static const _key = 'reaction.recent_emoji';

  static const defaults = <String>['❤️', '👍', '😂', '😮', '😢', '🔥'];

  /// As many as fit one line on a narrow phone next to the picker button.
  static const int maxEntries = 6;

  // Shared settings box — see FavoritesController for why it must be dynamic.
  Box<dynamic>? _box;

  @override
  List<String> build() {
    unawaited(_load());
    return defaults;
  }

  /// What a double-tap leaves: whatever you reached for last. One emoji, no
  /// menu — the point of the gesture is that the common case costs no decision,
  /// and the common case is personal.
  String get quickReaction => state.isEmpty ? defaults.first : state.first;

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider.openEncryptedBox<dynamic>(
        HiveBoxes.settings,
      );
      _box = box;
      final raw = box.get(_key);
      if (raw is List) {
        final loaded = raw.whereType<String>().take(maxEntries).toList();
        if (loaded.isNotEmpty) state = loaded;
      }
    } catch (e) {
      debugPrint('ReactionEmoji load failed: $e');
    }
  }

  /// Move [emoji] to the front, dropping the least recently used one off the
  /// end. Called on every reaction, from the strip and from the picker both.
  Future<void> remember(String emoji) async {
    if (emoji.isEmpty) return;
    final next = [emoji, ...state.where((e) => e != emoji)];
    state = next.length > maxEntries ? next.sublist(0, maxEntries) : next;
    await _persist();
  }

  /// Emergency Wipe: back to the stock six.
  Future<void> reset() async {
    state = defaults;
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('ReactionEmoji clear failed: $e');
    }
  }

  Future<void> _persist() async {
    try {
      await _box?.put(_key, state);
    } catch (e) {
      debugPrint('ReactionEmoji persist failed: $e');
    }
  }
}

final reactionEmojiControllerProvider =
    NotifierProvider<ReactionEmojiController, List<String>>(
  ReactionEmojiController.new,
);
