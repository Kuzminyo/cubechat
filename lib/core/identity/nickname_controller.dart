import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../storage/hive_cipher.dart';
import '../storage/hive_init.dart';

/// User-chosen display name. Persisted in the Hive settings box, used as the
/// peripheral's advertised BLE name and as our peerLabel when other devices
/// learn about us through Noise handshakes.
class NicknameController extends Notifier<String> {
  static const _key = 'nickname';
  static const defaultNickname = 'Anonymous';

  /// Cubechat ignores nicknames longer than this — keeps them inside BLE
  /// advertise budgets (~26 chars of useful name after framing overhead).
  static const int maxLength = 24;

  Box<String>? _box;

  @override
  String build() {
    unawaited(_load());
    return defaultNickname;
  }

  Future<void> _load() async {
    try {
      final box =
          await hiveCipherProvider.openEncryptedBox<String>(HiveBoxes.settings);
      _box = box;
      final v = box.get(_key);
      if (v != null && v.isNotEmpty) state = v;
    } catch (e) {
      debugPrint('NicknameController load failed: $e');
    }
  }

  /// Validate + persist. Trims whitespace, caps at [maxLength], ignores
  /// empty values.
  Future<void> set(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    final capped = trimmed.length > maxLength
        ? trimmed.substring(0, maxLength)
        : trimmed;
    state = capped;
    try {
      await _box?.put(_key, capped);
    } catch (e) {
      debugPrint('NicknameController persist failed: $e');
    }
  }

  /// Reset to the default — used by Emergency Wipe.
  Future<void> reset() async {
    state = defaultNickname;
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('NicknameController reset failed: $e');
    }
  }
}

final nicknameControllerProvider =
    NotifierProvider<NicknameController, String>(NicknameController.new);
