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

  double _minZoom = 1;
  double _maxZoom = 1;
  double _zoom = 1;
  double _zoomAtGestureStart = 1;
  bool _torchOn = false;

  /// True when the light is on, whichever kind of light this phone has.
  bool get torchOn => _torchOn;

  /// False once the hardware torch has refused, which is the normal answer on
  /// a front camera: almost no phone has a flash beside the selfie lens.
  ///
  /// Not a reason to hide the button — see [toggleTorch], which lights the
  /// screen instead. It is the same thing to the person holding it, and it is
  /// what every camera app does for a front-facing shot in the dark.
  bool _hardwareTorch = true;
  bool get usesScreenLight => _torchOn && !_hardwareTorch;

  /// How far this camera can be zoomed. Equal when it cannot be.
  double get minZoom => _minZoom;
  double get maxZoom => _maxZoom;
  bool get canZoom => _maxZoom > _minZoom + 0.01;

  /// Remember where a pinch started from, so the gesture is relative.
  void beginZoom() => _zoomAtGestureStart = _zoom;

  /// Apply a pinch. [scale] is cumulative from the start of the gesture.
  Future<void> zoomBy(double scale) async {
    final camera = _camera;
    if (camera == null || !canZoom) return;
    final next = (_zoomAtGestureStart * scale).clamp(_minZoom, _maxZoom);
    if ((next - _zoom).abs() < 0.01) return;
    _zoom = next;
    try {
      await camera.setZoomLevel(next);
    } catch (_) {
      // A camera that reports a range and then refuses it. Nothing to do and
      // nothing worth saying.
    }
    notifyListeners();
  }

  /// Let go and it goes back.
  ///
  /// A circle is a few seconds of your own face; a zoom held between one and
  /// the next would be a setting nobody set. This is a magnifying glass, not a
  /// lens choice.
  Future<void> resetZoom() async {
    final camera = _camera;
    if (camera == null || _zoom == _minZoom) return;
    _zoom = _minZoom;
    _zoomAtGestureStart = _minZoom;
    try {
      await camera.setZoomLevel(_minZoom);
    } catch (_) {}
    notifyListeners();
  }

  /// The light, hardware if there is one and the screen if there is not.
  Future<void> toggleTorch() async {
    final camera = _camera;
    if (camera == null) return;
    _torchOn = !_torchOn;
    if (_hardwareTorch) {
      try {
        await camera.setFlashMode(_torchOn ? FlashMode.torch : FlashMode.off);
      } catch (_) {
        // No flash on this lens. Fall through to lighting the screen, and do
        // not ask again for the rest of this recording.
        _hardwareTorch = false;
      }
    }
    notifyListeners();
  }

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
  ///
  /// [front] is the lens setting, read before the finger went down — see
  /// `CircleLensController` for why it is a setting and not a button here.
  Future<bool> start({bool front = true}) async {
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
      final wanted =
          front ? CameraLensDirection.front : CameraLensDirection.back;
      final lens = cameras.firstWhere(
        (c) => c.lensDirection == wanted,
        // A phone missing the lens that was asked for still gets to send a
        // circle with the other one, rather than a feature that is simply
        // missing on that device.
        orElse: () => cameras.first,
      );

      // 720p, and the bitrate said out loud.
      //
      // The resolution is the easy half: the disc is drawn at about 290 points
      // and a phone is three times that in pixels, so 480p was visibly soft on
      // the one screen a circle is always watched on.
      //
      // The bitrate is the half that decided whether circles worked at all.
      // Left to the platform default, 7.8 seconds came out at **12.2 MB** —
      // 12 Mbps, camcorder settings for a disc the size of a beer mat. Over
      // the media relay that is 371 publishes for eight seconds of talking,
      // and the transfer simply never finished; it is what "circles don't
      // send" turned out to mean. At 1.2 Mbps the same clip is about 1.2 MB
      // and 39 publishes.
      //
      // 24 fps rather than 30 for the same reason and at no visible cost: a
      // face talking is not a panning shot.
      final camera = CameraController(
        lens,
        ResolutionPreset.high,
        enableAudio: true,
        fps: 24,
        videoBitrate: 1200000,
        audioBitrate: 64000,
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
      // What this camera can do, asked once, before anything needs it.
      //
      // The minimum is set explicitly rather than assumed to be where the
      // camera opens: some phones start a front lens part-way in, which came
      // back as the preview being zoomed hard on a face with nobody having
      // touched it.
      try {
        _minZoom = await camera.getMinZoomLevel();
        _maxZoom = await camera.getMaxZoomLevel();
        _zoom = _minZoom;
        _zoomAtGestureStart = _minZoom;
        await camera.setZoomLevel(_minZoom);
      } catch (_) {
        _minZoom = 1;
        _maxZoom = 1;
        _zoom = 1;
      }
      _torchOn = false;
      _hardwareTorch = true;

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
    // The light does not survive the camera it belongs to.
    _torchOn = false;
    _zoom = _minZoom;
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
