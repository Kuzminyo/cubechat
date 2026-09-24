import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// Channel authors are identified by the short signing fingerprint on posts.
/// Hiding is local and survives restarts; it does not change the shared room.
class HiddenAuthors extends Notifier<Set<String>> {
  static const storageKey = 'moderation.hiddenAuthors';
  Box<dynamic>? _box;
  Future<void>? _loading;
  bool _touched = false;

  @override
  Set<String> build() {
    unawaited(_loading = _load());
    return <String>{};
  }

  Future<void> _load() async {
    try {
      _box =
          await hiveCipherProvider.openEncryptedBox<dynamic>(HiveBoxes.settings);
      if (_touched) return;
      final raw = _box?.get(storageKey);
      if (raw is List) {
        state = raw.whereType<String>().map((s) => s.toLowerCase()).toSet();
      }
    } catch (_) {
      // Keep the in-memory hides if encrypted storage is temporarily unavailable.
    }
  }

  Future<void> hide(String fingerprint) async {
    _touched = true;
    state = {...state, fingerprint.toLowerCase()};
    await _loading;
    await _box?.put(storageKey, state.toList());
  }

  Future<void> clear() async {
    _touched = true;
    state = <String>{};
    await _loading;
    await _box?.delete(storageKey);
  }
}

final hiddenAuthorsProvider =
    NotifierProvider<HiddenAuthors, Set<String>>(HiddenAuthors.new);
