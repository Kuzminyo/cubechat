import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// Whether relay media should wait while the phone only has cellular data.
///
/// Text, calls and control messages keep their own relay sockets either way;
/// only the media inbox waits, for Wi-Fi or for the "download now" row.
///
/// **Off by default.** It shipped on in 2026-09-21's build, which would have
/// held every voice note and circle on mobile data on every phone that never
/// opened the setting — and a voice note that does not arrive reads as a
/// broken messenger, not as a saved megabyte. It is the bad-connection mode's
/// switch, for whoever wants it.
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
    return false;
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      // Nothing is stored until the switch is touched, so a phone that ran
      // the default-on build and never touched it is not held to that default.
      state = box.get(_key, defaultValue: false) as bool;
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
    state = false;
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
