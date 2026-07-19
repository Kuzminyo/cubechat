import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// When the user last *read* each chat, keyed by the same id the chat list uses
/// (a peer's pubkey-hex, or a `#channel` name).
///
/// This is what makes the unread badge correct: before this existed the chat
/// list counted *every* inbound message forever, so a badge never cleared and
/// the "unread" state was meaningless. Now a chat's unread count is the inbound
/// messages whose `sentAt` is after its marker; opening a chat advances the
/// marker to now.
///
/// A purely local preference, so it lives in the shared settings box next to
/// favourites / background-mode rather than travelling with a peer's identity.
class ReadMarkersController extends Notifier<Map<String, DateTime>> {
  static const _key = 'read_markers';

  Box<dynamic>? _box;

  @override
  Map<String, DateTime> build() {
    unawaited(_load());
    return const <String, DateTime>{};
  }

  Future<void> _load() async {
    try {
      final box =
          await hiveCipherProvider.openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final raw = box.get(_key);
      if (raw is Map) {
        final loaded = <String, DateTime>{};
        raw.forEach((dynamic k, dynamic v) {
          if (k is String && v is String) {
            final dt = DateTime.tryParse(v);
            if (dt != null) loaded[k] = dt;
          }
        });
        // Merge under any markers set while the box was still loading.
        if (loaded.isNotEmpty) state = {...loaded, ...state};
      }
    } catch (e) {
      debugPrint('ReadMarkersController load failed: $e');
    }
  }

  DateTime? lastReadAt(String chatId) => state[chatId];

  /// Mark [chatId] read as of [at] (default: now). Never moves a marker
  /// backwards, so a stale re-open or an out-of-order call can't resurrect
  /// already-read messages as unread.
  Future<void> markRead(String chatId, {DateTime? at}) async {
    final when = at ?? DateTime.now();
    final existing = state[chatId];
    if (existing != null && !when.isAfter(existing)) return;
    state = {...state, chatId: when};
    await _persist();
  }

  /// Drop a marker — used when the chat itself is deleted.
  Future<void> forget(String chatId) async {
    if (!state.containsKey(chatId)) return;
    state = {...state}..remove(chatId);
    await _persist();
  }

  /// Used by Emergency Wipe.
  Future<void> clear() async {
    state = const <String, DateTime>{};
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('ReadMarkersController clear failed: $e');
    }
  }

  Future<void> _persist() async {
    try {
      await _box?.put(_key, {
        for (final e in state.entries) e.key: e.value.toIso8601String(),
      });
    } catch (e) {
      debugPrint('ReadMarkersController persist failed: $e');
    }
  }
}

final readMarkersControllerProvider =
    NotifierProvider<ReadMarkersController, Map<String, DateTime>>(
  ReadMarkersController.new,
);
