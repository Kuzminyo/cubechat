import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/util/debug_log.dart';

/// Recording a circle: a short round clip, front camera, sound on.
///
/// **Why this exists again.** Circles shipped once and were taken out in May,
/// because over Bluetooth a few seconds of video is 1500-plus chunks — it
/// swamped the write queue and starved announcements and text of airtime. The
/// removal note said they would need a different transport if they ever came
/// back. They have one now: the media relay lane, where a chunk is 32 KiB and
/// one publish rather than 4 KiB and a radio write.
///
/// A plain [ChangeNotifier] rather than a Riverpod notifier, unlike the voice
/// recorder beside it. This owns a camera — a native resource with a lifetime
/// that has to match one screen's, released the moment that screen goes — and
/// a provider outliving the widget that shows its preview is how a camera ends
/// up held open behind a chat nobody is looking at.
class CircleRecorder extends ChangeNotifier {
  CameraController? _camera;
  Timer? _ticker;
  Timer? _ceiling;
  DateTime? _startedAt;
  bool _stopping = false;
  String? error;

  /// Which attempt is the live one.
  ///
  /// Opening a camera takes the better part of a second, and a permission
  /// dialog takes as long as somebody reads it — both of which happen *after*
  /// the finger went down and can easily outlast it. Without this, letting go
  /// early stops a recording that has not begun, and the start that was still
  /// in flight then opens a camera nobody is holding and records into a file
  /// nobody will send. Every await inside [start] is followed by a check that
  /// it is still the current one.
  int _generation = 0;

  /// As long as a circle is allowed to run.
  ///
  /// A minute, which is what every other messenger settles on, and here it is
  /// also a transfer budget: at 480p a minute is a few megabytes and a few
  /// hundred relay publishes. Ten minutes would be a transfer nobody watches
  /// finish.
  static const Duration maxLength = Duration(seconds: 60);

  /// Under this, the press was a mis-tap rather than a message — the same
  /// floor the voice recorder uses, for the same reason.
  static const Duration minLength = Duration(milliseconds: 700);

  CameraController? get camera => _camera;
  bool get isRecording => _camera?.value.isRecordingVideo ?? false;

  /// A camera is open — which starts before recording does and ends with it.
  /// What the preview is shown against, so the circle appears the moment the
  /// finger goes down rather than a beat later.
  bool get isActive => _camera != null;

  /// True once the preview has a picture in it. The ring is drawn against
  /// this rather than against [isRecording], so the circle does not appear as
  /// a black hole while the camera opens.
  bool get isReady => _camera?.value.isInitialized ?? false;

  Duration get elapsed {
    final at = _startedAt;
    if (at == null) return Duration.zero;
    final d = DateTime.now().difference(at);
    return d > maxLength ? maxLength : d;
  }

  double get progress =>
      (elapsed.inMilliseconds / maxLength.inMilliseconds).clamp(0.0, 1.0);

  /// Called when the ceiling stops the recording on its own, so the screen can
  /// send what was captured without the finger having lifted.
  VoidCallback? onCeilingReached;

  /// Open the camera and start recording. False means nothing is running and
  /// [error] says why.
  Future<bool> start() async {
    error = null;
    if (_camera != null) return false;
    final generation = ++_generation;
    try {
      // Both, and in one go: a circle without sound is a silent film, and
      // asking for the microphone only after the camera is open means two
      // system dialogs stacked over a held finger.
      final grants = await <Permission>[
        Permission.camera,
        Permission.microphone,
      ].request();
      if (grants.values.any((s) => !s.isGranted)) {
        error = 'camera-or-microphone-denied';
        return false;
      }
      // Reading a permission dialog takes longer than holding a button.
      if (generation != _generation) return false;

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        error = 'no-camera';
        return false;
      }
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        // A phone with no front camera still gets to send one, pointing the
        // other way, rather than a feature that is simply missing.
        orElse: () => cameras.first,
      );

      // 720p. The circle is drawn at about 290 points and a phone is at three
      // times that in pixels, so 480p was visibly soft on the very screen it
      // was recorded on — which is the one place a circle is always watched.
      //
      // The ceiling that matters is not the byte count but the publish count:
      // at 720p a minute is a handful of megabytes, which is a few hundred
      // relay events, comfortably inside what [maxLength] and the media lane
      // are sized for. `veryHigh` and up would multiply that for detail a
      // 290-point disc cannot show.
      final camera = CameraController(
        front,
        ResolutionPreset.high,
        enableAudio: true,
      );
      _camera = camera;
      notifyListeners();
      await camera.initialize();
      // Gone while the camera was opening — a finger lifted inside the second
      // it takes. Nothing was recorded, so there is nothing to send.
      if (generation != _generation) {
        await _safelyDispose(camera);
        return false;
      }
      await camera.startVideoRecording();
      // And again: starting the recording is itself a round trip to the
      // platform, and the release can land inside it.
      if (generation != _generation) {
        try {
          final shot = await camera.stopVideoRecording();
          await _quietlyDelete(File(shot.path));
        } catch (_) {}
        await _safelyDispose(camera);
        return false;
      }
      _startedAt = DateTime.now();
      _ticker = Timer.periodic(
        // Only while a circle is being recorded, and it stops with it. The ring
        // has to move, and this is the one thing on screen that is happening.
        const Duration(milliseconds: 100),
        (_) => notifyListeners(),
      );
      _ceiling = Timer(maxLength, () => onCeilingReached?.call());
      notifyListeners();
      return true;
    } catch (e) {
      DebugLog.instance.log('CIRCLE', 'start failed: $e');
      error = '$e';
      await _release();
      return false;
    }
  }

  /// Stop and hand back the clip, or null if there is nothing worth sending.
  Future<({File file, Duration length})?> stop() async {
    final camera = _camera;
    if (camera == null || _stopping) return null;
    _stopping = true;
    final length = elapsed;
    try {
      if (!camera.value.isRecordingVideo) {
        await _release();
        return null;
      }
      final shot = await camera.stopVideoRecording();
      await _release();
      final file = File(shot.path);
      if (length < minLength) {
        await _quietlyDelete(file);
        return null;
      }
      return (file: file, length: length);
    } catch (e) {
      DebugLog.instance.log('CIRCLE', 'stop failed: $e');
      await _release();
      return null;
    } finally {
      _stopping = false;
    }
  }

  /// Throw the recording away, camera and file both.
  Future<void> cancel() async {
    final camera = _camera;
    if (camera == null) return;
    try {
      if (camera.value.isRecordingVideo) {
        final shot = await camera.stopVideoRecording();
        await _quietlyDelete(File(shot.path));
      }
    } catch (e) {
      DebugLog.instance.log('CIRCLE', 'cancel failed: $e');
    }
    await _release();
  }

  Future<void> _release() async {
    // Ends whatever [start] is in the middle of, as well as what is running.
    _generation++;
    _ticker?.cancel();
    _ticker = null;
    _ceiling?.cancel();
    _ceiling = null;
    _startedAt = null;
    final camera = _camera;
    _camera = null;
    notifyListeners();
    // Disposed after the field is cleared, so a rebuild triggered by the
    // notify above cannot hand a disposed controller to a preview.
    if (camera != null) await _safelyDispose(camera);
  }

  static Future<void> _safelyDispose(CameraController camera) async {
    try {
      await camera.dispose();
    } catch (_) {}
  }

  static Future<void> _quietlyDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  @override
  void dispose() {
    unawaited(_release());
    super.dispose();
  }
}
