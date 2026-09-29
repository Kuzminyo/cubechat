import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// The @name each contact was found by, `pubkeyHex → name`.
///
/// Only what this phone looked up: there is no reverse lookup on the server,
/// on purpose, so a contact added by QR has no name here even if they have
/// one. Kept like [ArchivedChatsController] keeps its set — merged under what
/// is already in memory, and a write before the box opened is not lost.
class KnownNamesController extends Notifier<Map<String, String>> {
  static const _key = 'cubeId.knownNames';

  Box<dynamic>? _box;
  Future<void>? _loading;
  bool _writePending = false;

  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  Map<String, String> build() {
    unawaited(_loading = _load());
    return const <String, String>{};
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final raw = box.get(_key);
      if (raw is Map) {
        state = {
          for (final e in raw.entries)
            if (e.key is String && e.value is String)
              e.key as String: e.value as String,
          ...state,
        };
      }
    } catch (e) {
      debugPrint('KnownNamesController load failed: $e');
    }
    if (_writePending && _box != null) {
      _writePending = false;
      await _persist();
    }
  }

  Future<void> remember(String pubkeyHex, String name) async {
    if (state[pubkeyHex] == name) return;
    state = {...state, pubkeyHex: name};
    await _persist();
  }

  Future<void> clear() async {
    state = const <String, String>{};
    await _persist();
  }

  Future<void> _persist() async {
    final box = _box;
    if (box == null) {
      _writePending = true;
      return;
    }
    try {
      await box.put(_key, Map<String, String>.from(state));
    } catch (e) {
      debugPrint('KnownNamesController persist failed: $e');
    }
  }
}

final knownNamesProvider =
    NotifierProvider<KnownNamesController, Map<String, String>>(
  KnownNamesController.new,
);
