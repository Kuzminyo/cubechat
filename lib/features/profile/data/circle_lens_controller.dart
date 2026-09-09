import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// Which camera a circle records with.
///
/// **A setting rather than a button on the recorder, and that is a limitation
/// being admitted rather than a design.** Switching lens mid-recording means
/// stopping the recording: the camera plugin has no way to hand a running
/// capture to the other sensor, so a button on the circle would either do
/// nothing until the next one — a control that appears not to work — or throw
/// away what had been recorded so far. Chosen here, before the finger goes
/// down, it simply is the camera you get.
///
/// Front by default, because a circle is a message with your face in it. The
/// back camera is for the other half of the reason people send them: showing
/// somebody what you are looking at.
class CircleLensController extends Notifier<bool> {
  static const _key = 'circle.front_camera';

  Box<dynamic>? _box;
  Future<void>? _loading;

  /// Completes once the stored choice has been read.
  ///
  /// The recorder waits for this before opening a camera. Without the wait it
  /// would open whichever lens the default names and the stored answer would
  /// arrive a moment later with nothing to apply it to — the same shape of bug
  /// the mesh switch had, where a setting did not survive a restart because
  /// something acted on it before it was loaded.
  Future<void> get loaded => _loading ?? Future<void>.value();

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
      state = box.get(_key) as bool? ?? true;
    } catch (e) {
      debugPrint('Circle lens load failed: $e');
    }
  }

  Future<void> set(bool front) async {
    state = front;
    try {
      await _box?.put(_key, front);
    } catch (e) {
      debugPrint('Circle lens persist failed: $e');
    }
  }

  /// Back to the default — used by Emergency Wipe, which puts every setting
  /// back to what a fresh install would have.
  Future<void> reset() async {
    state = true;
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('Circle lens reset failed: $e');
    }
  }
}

final circleLensProvider =
    NotifierProvider<CircleLensController, bool>(CircleLensController.new);
