import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:permission_handler/permission_handler.dart';

import '../storage/hive_cipher.dart';
import '../storage/hive_init.dart';
import 'background_service.dart';

/// User preference + orchestration for "keep running in the background".
///
/// When enabled (default), the app starts the Android foreground service so
/// BLE stays alive while backgrounded. The flag is persisted in the settings
/// box; the toggle in the profile screen flips it, and app startup applies it.
class BackgroundModeController extends Notifier<bool> {
  static const _key = 'backgroundMode';
  Box<dynamic>? _box;

  @override
  bool build() {
    unawaited(_load());
    return true; // default on
  }

  Future<void> _load() async {
    try {
      final box =
          await hiveCipherProvider.openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final v = box.get(_key) as bool?;
      if (v != null) state = v;
    } catch (e) {
      debugPrint('BackgroundMode load failed: $e');
    }
    // Apply whatever the (possibly restored) preference is.
    await apply();
  }

  /// Start or stop the foreground service to match [state]. Called on boot
  /// and whenever the toggle changes. Requests the notification permission
  /// the first time we turn it on (Android 13+).
  Future<void> apply() async {
    if (state) {
      // Foreground-service notification needs POST_NOTIFICATIONS on 13+.
      try {
        final status = await Permission.notification.status;
        if (!status.isGranted) {
          await Permission.notification.request();
        }
      } catch (e) {
        debugPrint('notification permission request failed: $e');
      }
      await BackgroundService.instance.start();
    } else {
      await BackgroundService.instance.stop();
    }
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    try {
      await _box?.put(_key, enabled);
    } catch (e) {
      debugPrint('BackgroundMode persist failed: $e');
    }
    await apply();
  }

  /// Surface the battery-optimisation exemption dialog — needed on Samsung to
  /// survive a swipe-away.
  Future<void> requestBatteryExemption() =>
      BackgroundService.instance.requestIgnoreBatteryOptimizations();

  Future<bool> isBatteryExempt() =>
      BackgroundService.instance.isIgnoringBatteryOptimizations();
}

final backgroundModeProvider =
    NotifierProvider<BackgroundModeController, bool>(
  BackgroundModeController.new,
);
