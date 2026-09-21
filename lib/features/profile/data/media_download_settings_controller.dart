import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// Whether relay media should wait while the phone only has cellular data.
///
/// The default is on: text, calls and control messages still use their normal
/// relay sockets, while the separate media inbox waits for Wi-Fi or an explicit
/// tap on a missing attachment.
class MediaDownloadSettingsController extends Notifier<bool> {
  static const _key = 'media.defer_on_mobile';

  Box<dynamic>? _box;
  Future<void>? _loading;

  Future<void> get loaded => _loading ?? Future<void>.value();

  Future<bool> resolved() async {
    await loaded;
    return state;
  }

  @override
  bool build() {
    unawaited(_loading = _load());
    return true;
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      state = box.get(_key, defaultValue: true) as bool;
    } catch (e) {
      debugPrint('Media download setting load failed: $e');
    }
  }

  Future<void> set(bool deferOnMobile) async {
    state = deferOnMobile;
    await loaded;
    state = deferOnMobile;
    try {
      await _box?.put(_key, deferOnMobile);
    } catch (e) {
      debugPrint('Media download setting persist failed: $e');
    }
  }

  Future<void> reset() async {
    await loaded;
    state = true;
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('Media download setting reset failed: $e');
    }
  }
}

final mediaDownloadSettingsProvider =
    NotifierProvider<MediaDownloadSettingsController, bool>(
  MediaDownloadSettingsController.new,
);
