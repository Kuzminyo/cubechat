import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// The message a chat currently has pinned.
@immutable
class PinnedMessage {
  const PinnedMessage({required this.wireId, required this.pinnedAt});

  /// Transport [Message.wireId] of the pinned message — the handle both sides
  /// share, so a pin travels between devices without needing local row ids.
  final String wireId;

  /// When the pin was applied on this device (ours, or the moment a peer's pin
  /// landed). Used to decide which of two pins wins.
  final DateTime pinnedAt;

  @override
  bool operator ==(Object other) =>
      other is PinnedMessage &&
      other.wireId == wireId &&
      other.pinnedAt == pinnedAt;

  @override
  int get hashCode => Object.hash(wireId, pinnedAt);
}

/// Pinned message per chat, keyed the way the chat list keys chats: a peer's
/// pubkey-hex or a `#channel` name.
///
/// One pin per chat, deliberately: a stack of pins needs its own list screen and
/// a way to page between them, and the thing people actually reach for is "keep
/// this one where I can see it". Pinning something else replaces it.
///
/// Kept in the shared settings box next to favourites — it's small, and it is
/// *not* part of a peer's identity record. Unlike favourites, though, a pin is
/// conversation state rather than a private preference: [MessagingService]
/// mirrors every change to the other side, so both people see the same banner.
class PinnedController extends Notifier<Map<String, PinnedMessage>> {
  static const _key = 'pinned_messages';

  Box<dynamic>? _box;
  Future<void>? _loading;

  /// Completes once the persisted pins have been merged into [state]; tests
  /// await it.
  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  Map<String, PinnedMessage> build() {
    unawaited(_loading = _load());
    return const <String, PinnedMessage>{};
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final raw = box.get(_key);
      if (raw is! Map) return;
      final loaded = <String, PinnedMessage>{};
      for (final entry in raw.entries) {
        final chatId = entry.key;
        final value = entry.value;
        if (chatId is! String || value is! Map) continue;
        final wireId = value['wireId'];
        final at = DateTime.tryParse((value['atIso'] as String?) ?? '');
        if (wireId is! String || at == null) continue;
        loaded[chatId] = PinnedMessage(wireId: wireId, pinnedAt: at);
      }
      if (loaded.isNotEmpty) {
        // Merge under anything pinned while the box was still opening.
        state = {...loaded, ...state};
      }
    } catch (e) {
      debugPrint('PinnedController load failed: $e');
    }
  }

  PinnedMessage? pinnedIn(String chatId) => state[chatId];

  bool isPinned(String chatId, String wireId) =>
      state[chatId]?.wireId == wireId;

  /// Pin [wireId] in [chatId], replacing whatever was pinned there. [at] lets
  /// the caller stamp a peer's pin with the time it arrived.
  Future<void> pin(String chatId, String wireId, {DateTime? at}) async {
    state = {
      ...state,
      chatId: PinnedMessage(wireId: wireId, pinnedAt: at ?? DateTime.now()),
    };
    await _persist();
  }

  /// Clear the pin in [chatId]. Passing [wireId] makes it conditional — an
  /// unpin that names a message which is no longer the pinned one is stale (two
  /// devices racing) and must not clear the newer pin.
  Future<void> unpin(String chatId, {String? wireId}) async {
    final current = state[chatId];
    if (current == null) return;
    if (wireId != null && current.wireId != wireId) return;
    state = {...state}..remove(chatId);
    await _persist();
  }

  /// Drop a chat's pin because the chat itself is gone.
  Future<void> forget(String chatId) => unpin(chatId);

  /// Used by Emergency Wipe.
  Future<void> clear() async {
    state = const <String, PinnedMessage>{};
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('PinnedController clear failed: $e');
    }
  }

  Future<void> _persist() async {
    final box = _box;
    if (box == null) return; // not loaded yet; next change rewrites the lot
    try {
      await box.put(_key, {
        for (final e in state.entries)
          e.key: {
            'wireId': e.value.wireId,
            'atIso': e.value.pinnedAt.toIso8601String(),
          },
      });
    } catch (e) {
      debugPrint('PinnedController persist failed: $e');
    }
  }
}

final pinnedControllerProvider =
    NotifierProvider<PinnedController, Map<String, PinnedMessage>>(
  PinnedController.new,
);
