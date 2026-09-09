import 'dart:async';
import 'dart:io';

import 'package:camera_android/camera_android.dart';
import 'package:camera_android_camerax/camera_android_camerax.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../../core/util/debug_log.dart';

/// Which Android camera implementation the app talks to.
///
/// Flutter's `camera` plugin has two on Android. **CameraX** is the default
/// and what this app ships: a compatibility layer Google maintains over the
/// platform's Camera2 API, which is why it can do things Camera2 cannot be
/// made to do here — mirroring an encoded front-facing clip, and swapping the
/// sensor inside a running recording, which is what makes a circle able to
/// turn round mid-sentence. **Camera2** is the older, thinner binding.
///
/// The reason for a switch is that neither works everywhere. CameraX picks a
/// configuration per device from Google's own compatibility data, and on a
/// phone that data is wrong about, the failure is total and unfixable from
/// inside the app: a preview that never opens, a recording with no sound, a
/// flip that hangs. Telegram ships this same escape hatch under this same
/// name, and for this same reason — when the layer is the problem, the only
/// repair a person can make is to use the other one.
///
/// **What it costs, stated plainly, because the switch is not free:**
///
///   * a front-facing circle comes back mirror-image. The fix for that lives
///     in our patched CameraX (`third_party/camera_android_camerax`, one call
///     to `MIRROR_MODE_ON_FRONT_ONLY`) and Camera2 has no equivalent;
///   * flipping the camera mid-recording is not supported, so the button waits
///     until the next circle instead.
///
/// Off by default and worth leaving off. It is here for the phone where
/// circles do not work at all, where a mirrored clip is a better outcome than
/// no clip.
///
/// iOS has one implementation and this setting does nothing there.
class CameraApiController extends Notifier<bool> {
  static const _key = 'camera.legacy_camera2';

  Box<dynamic>? _box;
  Future<void>? _loading;

  /// Completes once the stored choice has been read and applied.
  ///
  /// Boot waits for this before anything can open a camera. The registration
  /// is global and one-way per launch in practice: a controller already built
  /// holds the implementation it was made with, so a change made here reaches
  /// the *next* camera, not the open one. Nothing opens a camera during
  /// startup, so at boot there is never an open one to disagree with.
  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  bool build() {
    unawaited(_loading = _load());
    return false;
  }

  Future<void> _load() async {
    if (!Platform.isAndroid) return;
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final legacy = box.get(_key) as bool? ?? false;
      state = legacy;
      _apply(legacy);
    } catch (e) {
      debugPrint('Camera API load failed: $e');
    }
  }

  Future<void> set(bool legacy) async {
    state = legacy;
    _apply(legacy);
    try {
      await _box?.put(_key, legacy);
    } catch (e) {
      debugPrint('Camera API persist failed: $e');
    }
  }

  /// Back to CameraX — used by Emergency Wipe, which puts every setting back
  /// to what a fresh install would have.
  Future<void> reset() async {
    state = false;
    _apply(false);
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('Camera API reset failed: $e');
    }
  }

  /// Point the plugin at one implementation or the other.
  ///
  /// Said out loud in the log because it changes what every camera in the app
  /// is, and a bug report from a phone running the non-default one is a
  /// different bug report. The boot line is the first place to look when a
  /// mirrored circle or a dead flip button turns up.
  void _apply(bool legacy) {
    if (!Platform.isAndroid) return;
    CameraPlatform.instance = legacy ? AndroidCamera() : AndroidCameraCameraX();
    DebugLog.instance.log('CAM', legacy ? 'using Camera2' : 'using CameraX');
  }
}

final cameraApiProvider =
    NotifierProvider<CameraApiController, bool>(CameraApiController.new);
