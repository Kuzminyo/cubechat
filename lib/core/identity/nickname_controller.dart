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

  // The settings box is shared with other controllers (background mode,
  // etc.), so it's opened as Box<dynamic> everywhere — Hive forbids opening
  // one box under two different type parameters.
  Box<dynamic>? _box;

  late Future<void> _loading;

  /// Set once the user has chosen a name this session, so a slow disk read
  /// can't come back and overwrite their choice with the previous value.
  bool _userSet = false;

  /// Completes once the stored nickname has been read back from disk.
  ///
  /// [state] is the default until then, so anything that bakes the nickname
  /// into something long-lived must await this first. The BLE advertisement is
  /// the case that bit us: it read the default mid-load and kept advertising
  /// "Anonymous <tag>" for the whole session while the mesh announced the real
  /// name — the user's rename appeared to do nothing.
  Future<void> get loaded => _loading;

  @override
  String build() {
    _loading = _load();
    return defaultNickname;
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final v = box.get(_key) as String?;
      if (v != null && v.isNotEmpty && !_userSet) state = v;
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
    _userSet = true;
    // A rename that lands before the box finishes opening would otherwise be
    // dropped on the floor (_box still null) and reappear on next launch.
    await _loading;
    try {
      await _box?.put(_key, capped);
    } catch (e) {
      debugPrint('NicknameController persist failed: $e');
    }
  }

  /// Reset to the default — used by Emergency Wipe.
  Future<void> reset() async {
    state = defaultNickname;
    _userSet = true;
    await _loading;
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('NicknameController reset failed: $e');
    }
  }
}

final nicknameControllerProvider =
    NotifierProvider<NicknameController, String>(NicknameController.new);
