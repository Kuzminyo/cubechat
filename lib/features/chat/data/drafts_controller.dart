import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

@immutable
class ChatDraft {
  const ChatDraft({required this.text, required this.updatedAt});

  final String text;
  final DateTime updatedAt;
}

class DraftsController extends Notifier<Map<String, ChatDraft>> {
  static const _key = 'chat_drafts_v1';

  Box<dynamic>? _box;
  Timer? _persistTimer;
  Future<void>? _loading;

  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  Map<String, ChatDraft> build() {
    ref.onDispose(() => _persistTimer?.cancel());
    unawaited(_loading = _load());
    return const <String, ChatDraft>{};
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final raw = box.get(_key);
      if (raw is! Map) return;
      final loaded = <String, ChatDraft>{};
      for (final entry in raw.entries) {
        final id = entry.key;
        final value = entry.value;
        if (id is! String || value is! Map) continue;
        final text = value['text'];
        final updatedAt =
            DateTime.tryParse((value['updatedAt'] as String?) ?? '');
        if (text is! String || text.trim().isEmpty || updatedAt == null)
          continue;
        loaded[id] = ChatDraft(text: text, updatedAt: updatedAt);
      }
      state = {...loaded, ...state};
    } catch (e) {
      debugPrint('DraftsController load failed: $e');
    }
  }

  void update(String chatId, String text) {
    if (chatId.isEmpty) return;
    if (text.trim().isEmpty) {
      state = {...state}..remove(chatId);
    } else {
      state = {
        ...state,
        chatId: ChatDraft(text: text, updatedAt: DateTime.now()),
      };
    }
    _schedulePersist();
  }

  Future<void> clear(String chatId) async {
    await loaded;
    if (!state.containsKey(chatId)) return;
    state = {...state}..remove(chatId);
    await _persist();
  }

  Future<void> clearAll() async {
    await loaded;
    state = const <String, ChatDraft>{};
    _persistTimer?.cancel();
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('DraftsController clear failed: $e');
    }
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 350), _persist);
  }

  Future<void> _persist() async {
    if (_box == null) {
      await loaded;
    }
    final box = _box;
    if (box == null) return;
    try {
      await box.put(_key, {
        for (final entry in state.entries)
          entry.key: {
            'text': entry.value.text,
            'updatedAt': entry.value.updatedAt.toIso8601String(),
          },
      });
    } catch (e) {
      debugPrint('DraftsController persist failed: $e');
    }
  }
}

final draftsControllerProvider =
    NotifierProvider<DraftsController, Map<String, ChatDraft>>(
  DraftsController.new,
);
