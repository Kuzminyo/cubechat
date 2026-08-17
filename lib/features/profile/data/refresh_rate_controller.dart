import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../../core/util/debug_log.dart';

/// Whether the app asks Android for the panel's full refresh rate.
///
/// The request itself is not the extravagance it sounds like — see the note in
/// `main.dart`: on a 90/120 Hz phone that MIUI has parked at 60, the app was
/// running a 60 Hz animation on a 90 Hz panel, and the uneven pacing read as
/// stutter even though no frame was being missed. Stating the preference fixed
/// that.
///
/// What it also does is double the number of frames the GPU draws, and this app
/// is measurably GPU-bound: raster p90 sits near 10 ms against a build p90 of
/// under 5, so it is the painting and not the logic that costs. At 120 Hz every
/// one of those frames gets 8.3 ms; at 60 Hz it gets 16.7 and there are half as
/// many. On a phone that is warm rather than stuttering, that is the largest
/// single knob there is.
///
/// So it is a knob, and the person holding the warm phone turns it. Default on,
/// because smoothness is the right default and because turning it off silently
/// would undo a fix somebody asked for.
///
/// **Android only.** iOS is held at 60 through
/// `CADisableMinimumFrameDurationOnPhone` in Info.plist, set for exactly this
/// reason; there is nothing here to decide.
class RefreshRateController extends Notifier<bool> {
  static const _key = 'app.high_refresh_rate';

  Box<dynamic>? _box;

  @override
  bool build() {
    unawaited(_load());
    return true;
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider.openEncryptedBox<dynamic>(
        HiveBoxes.settings,
      );
      _box = box;
      final saved = box.get(_key);
      if (saved is bool && saved != state) {
        state = saved;
        await apply();
      }
    } catch (e) {
      debugPrint('RefreshRate load failed: $e');
    }
  }

  /// Whether this device has anything to decide. False on iOS and on a phone
  /// whose panel offers one mode, so the setting can hide rather than offering
  /// a switch that does nothing.
  static bool get isAdjustable => !kIsWeb && Platform.isAndroid;

  Future<void> select(bool high) async {
    if (high == state) return;
    state = high;
    try {
      await _box?.put(_key, high);
    } catch (e) {
      debugPrint('RefreshRate persist failed: $e');
    }
    await apply();
  }

  /// Push the current choice at the platform.
  ///
  /// Best-effort in both directions: plenty of devices expose no mode list at
  /// all, and the platform default is a perfectly good answer. What it must not
  /// do is throw — this runs during startup.
  Future<void> apply() async {
    if (!isAdjustable) return;
    try {
      if (state) {
        await FlutterDisplayMode.setHighRefreshRate();
      } else {
        await FlutterDisplayMode.setLowRefreshRate();
      }
      final active = await FlutterDisplayMode.active;
      DebugLog.instance.log(
        'DISPLAY',
        'mode ${active.width}x${active.height} '
            '@${active.refreshRate.toStringAsFixed(1)}Hz '
            '(${state ? 'high' : 'low'} requested)',
      );
    } catch (e) {
      DebugLog.instance.log('DISPLAY', 'refresh-rate request failed: $e');
    }
  }
}

final refreshRateProvider =
    NotifierProvider<RefreshRateController, bool>(RefreshRateController.new);
