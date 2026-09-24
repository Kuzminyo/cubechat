import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// Enabled by default. Only the local display changes; the sender is not
/// notified and message bytes are never sent to a moderation service.
class FilterSettings extends Notifier<bool> {
  static const storageKey = 'moderation.filterEnabled';
  Box<dynamic>? _box;
  Future<void>? _loading;
  bool _touched = false;

  @override
  bool build() {
    unawaited(_loading = _load());
    return true;
  }

  Future<void> _load() async {
    try {
      _box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      if (_touched) return;
      final raw = _box?.get(storageKey);
      if (raw is bool) state = raw;
    } catch (_) {
      // Failure to read settings keeps the safe default on.
    }
  }

  Future<void> setEnabled(bool enabled) async {
    _touched = true;
    state = enabled;
    await _loading;
    await _box?.put(storageKey, enabled);
  }

  Future<void> reset() async {
    _touched = true;
    state = true;
    await _loading;
    await _box?.delete(storageKey);
  }
}

final filterEnabledProvider =
    NotifierProvider<FilterSettings, bool>(FilterSettings.new);
