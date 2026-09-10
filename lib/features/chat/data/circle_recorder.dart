import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../core/util/debug_log.dart';

/// Recording a circle: a short round clip, front camera, sound on.
///
/// **Why this exists again.** Circles shipped once and were taken out in May,
/// because over Bluetooth a few seconds of video is 1500-plus chunks — it
/// swamped the write queue and starved announcements and text of airtime. The
/// removal note said they would need a different transport if they ever came
/// back. They have one now: the media relay lane, where a chunk is 63 KiB and
/// one publish rather than 4 KiB and a radio write.
///
/// A plain [ChangeNotifier] rather than a Riverpod notifier, unlike the voice
/// recorder beside it. This owns a camera — a native resource with a lifetime
/// that has to match one screen's, released the moment that screen goes — and
/// a provider outliving the widget that shows its preview is how a camera ends
/// up held open behind a chat nobody is looking at.
class CircleRecorder extends ChangeNotifier {
  CircleRecorder({
    Future<List<CameraDescription>> Function()? listCameras,
    CameraController Function(CameraDescription)? createCamera,
  })  : _listCameras = listCameras ?? availableCameras,
        _createCamera = createCamera ?? _makeCamera;

  final Future<List<CameraDescription>> Function() _listCameras;
  final CameraController Function(CameraDescription) _createCamera;

  /// Camera exception codes that mean the person said no, or was never asked.
  ///
  /// **This is why circles did nothing at all on iOS.** The recorder used to
  /// ask `permission_handler` for camera and microphone before opening
  /// anything. On iOS that package compiles each permission out unless the
  /// Podfile defines a macro for it — `PermissionHandlerEnums.h` reads
  /// `#ifndef PERMISSION_CAMERA / #define PERMISSION_CAMERA 0` — and this repo
  /// has no Podfile at all, so Flutter generates the default one, which
  /// defines nothing. The request therefore returned "not granted" without any
  /// dialog ever appearing, every single time, and the screen showed
  /// "circles need the camera and microphone" to someone who had never been
  /// asked for either.
  ///
  /// Nothing asks ahead any more. The camera plugin requests both itself when
  /// the controller initializes — `AVCaptureDevice.requestAccess` on iOS,
  /// CameraX's permission manager on Android — and reports a refusal as a
  /// [CameraException] with one of these codes. One fewer package in the path,
  /// and no build-time switch that can silently turn it off.
  static const _deniedCodes = {
    'CameraAccessDenied',
    'CameraAccessDeniedWithoutPrompt',
    'CameraAccessRestricted',
    'AudioAccessDenied',
    'AudioAccessDeniedWithoutPrompt',
    'AudioAccessRestricted',
  };

  /// Request 1080p60, with native negotiation down for sensors that cannot.
  ///
  /// **The resolution is asked for, and it is oversampling.** A circle is a
  /// square cut from the frame, so what reaches the screen is the shorter
  /// side: 1080 pixels from a 1080p capture. The disc is drawn at 216 logical
  /// points, which on a 1080×2340 phone at 3× is about 650 physical pixels —
  /// so 720 was already above what is displayed and 1080 is roughly 1.7× it.
  /// The visible gain over 720p is small. It is here because it was asked for,
  /// and because the one place it does show is a face filling the disc on a
  /// tablet or a future larger crop.
  ///
  /// **The bitrate is what decides whether it arrives.** Left to the platform
  /// a clip came out at 12 Mbps — camcorder settings for a disc the size of a
  /// beer mat, and 371 relay publishes for eight seconds. Over the internet
  /// every chunk is one publish and one round trip, so bytes are time.
  ///
  /// 5 Mbps rather than the 7.2 that would hold 720p60's bits per pixel across
  /// 2.25× the pixels. A talking head is nearly still, which is the case an
  /// encoder handles best, so the shortfall costs little; the alternative
  /// costs 2.25× the transfer on a phone uplink. Eight seconds is about 5 MB
  /// and 80 publishes at [kRelayMediaChunkData], against 51 before.
  ///
  /// **2.2 Mbps at 960×720, and the resolution is the lever that moved.**
  ///
  /// The comment here previously said the lever for file size at a fixed frame
  /// rate is resolution rather than bitrate, named 960×720 as the option, and
  /// did not take it because sharpness had been asked for more recently than
  /// size. A report from a weak phone settled it: the recorder lagged, and
  /// 1080p60 is why.
  ///
  /// **The pixels were never displayed.** The disc is 248 logical points, which
  /// is 744 physical pixels on a 1080-wide phone at 3× and fewer on anything
  /// else. A 720-tall capture through a square crop is exactly what the screen
  /// shows; 1440×1080 was 1.44× that in each direction, encoded, transmitted,
  /// and then thrown away by the scaler. Sharpness on the disc is unchanged
  /// because the disc never had more than 744 pixels to give.
  ///
  /// **What it cost was the phone and the transfer.** A minute at 1080p60 and
  /// 5 Mbps is 37 MB and some six hundred relay publishes, each a round trip —
  /// a transfer nobody watches finish, on top of an encode a weak device cannot
  /// keep up with. The same minute is now 16 MB and 270 publishes.
  ///
  /// Bits per pixel are held: 960×720 is 44% of 1440×1080's pixels, and
  /// 2.2 Mbps is 44% of 5. That matters because the last time this number moved
  /// without the pixel count moving with it — 5 down to 3.75 in 1024 — the
  /// smoothness went with it and had to be put back.
  ///
  /// Frame rate stays at 60. It is the part a person sees immediately, and it
  /// is the part that was explicitly not to be touched.
  static CameraController _makeCamera(CameraDescription lens) =>
      CameraController(
        lens,
        ResolutionPreset.veryHigh,
        enableAudio: true,
        fps: 60,
        videoBitrate: 2200000,
        audioBitrate: 64000,
      );

  /// Prefer the widest advertised lens; unknown logical cameras still expose
  /// their full range through getMinZoomLevel. No extra digital zoom is added.
  ///
  /// **Widest, except on the back, where it is the main lens.** An ultra-wide
  /// is the right answer facing you: it is the only way to get more than a
  /// face into a disc held at arm's length, and on the front there is rarely
  /// more than one lens anyway. Facing away it is the wrong answer, and
  /// reported as such — a phone's ultra-wide is its cheapest sensor, smaller,
  /// slower and softer than the main one, and nobody pointing the camera at
  /// something wants the soft lens for the sake of fitting more in. Behind you
  /// there is a subject; in front of you there is you.
  @visibleForTesting
  static CameraDescription widestLens(
    List<CameraDescription> cameras,
    CameraLensDirection direction,
  ) {
    final choices = cameras.where((c) => c.lensDirection == direction).toList();
    if (choices.isEmpty) return cameras.first;
    final rear = direction == CameraLensDirection.back;
    int rank(CameraDescription c) => switch (c.lensType) {
          CameraLensType.ultraWide => rear ? 2 : 0,
          CameraLensType.wide => rear ? 0 : 1,
          CameraLensType.unknown => rear ? 1 : 2,
          CameraLensType.telephoto => 3,
        };
    // Preserve the native field-of-view order when Android reports unknown
    // lens types; List.sort does not guarantee the order of equal elements.
    return choices
        .reduce((best, lens) => rank(lens) < rank(best) ? lens : best);
  }

  /// Stabilisation is **off**, and that is a trade rather than an oversight.
  ///
  /// Electronic stabilisation works by keeping a margin of frame in hand to
  /// shift into, so it is a crop — ten per cent or so at level 1. It went in
  /// and "the picture is too close in" came back in the same round, on a
  /// recorder whose zoom is already pinned to the lens minimum. With nothing
  /// else left to widen, this is the one crop that can be given back without
  /// touching the 1080p that was asked for in the same breath.
  ///
  /// **What is actually making it tight is the shape of the frame, and that
  /// cannot be fixed here.** A phone builds a 16:9 video mode by keeping the
  /// sensor's full width and cutting its height, which in portrait means about
  /// a quarter less across than the sensor's native 4:3 — and the disc is a
  /// square that shows the full width, so it shows exactly that narrowed view.
  /// The lever for that one is [ResolutionPreset], and pulling it costs the
  /// resolution. It is a choice for whoever reads this next, not one to make
  /// quietly.
  ///
  /// [widestLens] already asks for an ultra-wide where the phone has one, and
  /// almost none have one facing the user.
  Future<void> _logLens(CameraController camera) async {
    // The capture size is in here because "the smoothness is gone" and "it is
    // too tight" are both questions about what the sensor actually gave us,
    // and neither could be answered from a log that only named the lens. A
    // 4:3 request that a device could not honour shows up as a 16:9 preview
    // size; a frame rate that fell back shows up as neither, which is the next
    // thing this line needs.
    final size = camera.value.previewSize;
    DebugLog.instance.log(
      'CIRCLE',
      'lens=${camera.description.name} '
          '${size == null ? 'size unknown' : '${size.width.toInt()}x'
              '${size.height.toInt()}'} '
          'zoom=$_minZoom '
          'stabilization=${camera.value.videoStabilizationMode.name} '
          '(not requested — it crops)',
    );
  }

  CameraController? _camera;
  Timer? _ticker;
  Timer? _ceiling;
  DateTime? _startedAt;
  bool _stopping = false;
  bool _starting = false;
  bool _disposed = false;
  Future<void>? _lensChange;
  Future<({File file, Duration length})?>? _ending;
  bool get isFlipping => _flipping;
  bool get isFinishing => _stopping;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

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
    _notify();
  }

  /// Let go and it goes back.
  ///
  /// A circle is a few seconds of your own face; a zoom held between one and
  /// the next would be a setting nobody set. This is a magnifying glass, not a
  /// lens choice.
  ///
  /// Eased back rather than snapped. One `setZoomLevel` to the minimum is a
  /// cut: the picture is at 3x in one frame and at 1x in the next, which reads
  /// as the camera flinching when you let go. The pinch itself is smooth
  /// because a finger moves smoothly, and the release was the only part of the
  /// gesture that was not.
  ///
  /// 220 ms of ease-out in 16 ms steps, which is a frame each at 60 Hz. The
  /// platform call is awaited inside the loop, so a camera that cannot keep up
  /// falls behind into fewer, larger steps instead of queueing a hundred of
  /// them behind the finger.
  static const Duration _zoomEase = Duration(milliseconds: 260);
  static const Duration _zoomStep = Duration(milliseconds: 16);

  /// Which reset is the live one, so a second pinch cancels the first's ride
  /// home instead of fighting it frame by frame.
  int _zoomGeneration = 0;

  /// A `setZoomLevel` is still on its way to the platform.
  ///
  /// This is what makes the ride even, and the first version did not have it.
  /// That one awaited each call and then slept 16 ms, so every step really
  /// took 16 ms *plus* however long the platform took — a hundred microseconds
  /// sometimes and thirty milliseconds others — and the picture arrived home in
  /// visible lurches. The animation is driven by the clock now and the camera
  /// is asked to keep up: a tick that finds the previous call unfinished skips
  /// its own rather than queueing behind it, so a slow camera drops frames of
  /// the ride instead of stretching it.
  bool _zoomBusy = false;

  Future<void> resetZoom() async {
    final camera = _camera;
    if (camera == null || _zoom == _minZoom) return;
    final generation = ++_zoomGeneration;
    final from = _zoom;
    final span = from - _minZoom;
    _zoomAtGestureStart = _minZoom;
    final started = DateTime.now();
    final done = Completer<void>();
    Timer.periodic(_zoomStep, (timer) {
      if (generation != _zoomGeneration || _camera != camera || _disposed) {
        timer.cancel();
        if (!done.isCompleted) done.complete();
        return;
      }
      // Position from elapsed wall time, never from the tick count. A timer
      // that fires late must not make the animation longer, only coarser.
      final elapsed = DateTime.now().difference(started).inMicroseconds;
      final t = (elapsed / _zoomEase.inMicroseconds).clamp(0.0, 1.0);
      // Ease-out cubic: most of the distance early, the last of it slowly, so
      // the picture settles rather than arrives.
      final eased = 1 - math.pow(1 - t, 3);
      _zoom = t >= 1 ? _minZoom : from - span * eased;
      _notify();
      if (!_zoomBusy) {
        _zoomBusy = true;
        camera.setZoomLevel(_zoom).catchError((_) {}).whenComplete(() {
          _zoomBusy = false;
        });
      }
      if (t >= 1) {
        timer.cancel();
        if (!done.isCompleted) done.complete();
      }
    });
    await done.future;
    if (generation != _zoomGeneration || _disposed) return;
    // The last tick may have been the one that was skipped for being busy, and
    // the ride has to end exactly at the minimum rather than near it.
    _zoom = _minZoom;
    try {
      await camera.setZoomLevel(_minZoom);
    } catch (_) {}
    _notify();
  }

  /// How much brighter than the meter says, in stops.
  ///
  /// **A face is not the average of the room, and a camera meters the room.**
  /// A phone held at arm's length indoors puts a head against a wall, a window
  /// or a ceiling light, and automatic exposure balances all of it — which
  /// lands the face a stop under, in shadow, every time. Compared against
  /// Telegram's round video on the same phone on 2026-09-10: same room, same
  /// lens, theirs visibly brighter.
  ///
  /// Two thirds of a stop. Enough to lift a face out of shadow, small enough
  /// that a bright room does not blow out — this is a correction to metering,
  /// not a brightness setting, and there is nobody to turn it back down.
  static const double _exposureStops = 0.67;

  /// Nudge the exposure, if this camera has any to give.
  ///
  /// The range is asked for rather than assumed: it is in stops on Android and
  /// in stops on iOS, but the bounds differ per device, and a value outside
  /// them throws. Clamped, and a camera that offers no range at all is left
  /// exactly as it was.
  Future<void> _brighten(CameraController camera) async {
    try {
      final min = await camera.getMinExposureOffset();
      final max = await camera.getMaxExposureOffset();
      if (max <= min) return;
      final offset = _exposureStops.clamp(min, max);
      await camera.setExposureOffset(offset);
      DebugLog.instance.log('CIRCLE', 'exposure +$offset EV (of $min..$max)');
    } catch (e) {
      DebugLog.instance.log('CIRCLE', 'exposure not adjustable: $e');
    }
  }

  /// The light: the screen on a front lens, the flash on a back one.
  ///
  /// Decided by which way the camera points rather than by asking the hardware
  /// and seeing what happens. Asking was the first attempt and it failed
  /// silently: on this phone `setFlashMode(torch)` on the front camera
  /// *succeeds* and lights nothing, so the button turned itself on, the screen
  /// stayed dark, and there was no error to fall back from. A front camera
  /// with a flash beside it does not exist on any phone this app will meet.
  Future<void> toggleTorch() async {
    final camera = _camera;
    if (camera == null) return;
    _torchOn = !_torchOn;
    if (_hardwareTorch) {
      try {
        await camera.setFlashMode(_torchOn ? FlashMode.torch : FlashMode.off);
      } catch (e) {
        DebugLog.instance
            .log('CIRCLE', 'torch refused ($e) — using the screen');
        _hardwareTorch = false;
      }
    }
    _notify();
  }

  /// Camera 0.12 supports changing sensors inside a persistent recording.
  /// Stop/delete/start lost the first part and raced with cancel during release.
  Future<void> flipLens() {
    if (_camera == null ||
        !isRecording ||
        _flipping ||
        _stopping ||
        _disposed) {
      return Future<void>.value();
    }
    _flipping = true;
    error = null;
    _notify();
    final change = _flipLens();
    _lensChange = change;
    return change;
  }

  Future<void> _flipLens() async {
    final camera = _camera!;
    final generation = _generation;
    try {
      final cameras = await _listCameras();
      if (generation != _generation) return;
      final wanted =
          _front ? CameraLensDirection.back : CameraLensDirection.front;
      final choices = cameras.where((lens) => lens.lensDirection == wanted);
      if (choices.isEmpty) {
        error = 'no-other-camera';
        return;
      }
      try {
        await camera.setFlashMode(FlashMode.off);
      } catch (_) {}
      if (generation != _generation) return;
      final lens = widestLens(choices.toList(), wanted);
      await camera.setDescription(lens);
      if (generation != _generation) return;
      _front = lens.lensDirection == CameraLensDirection.front;
      _hardwareTorch = !_front;
      _torchOn = false;
      _minZoom = await camera.getMinZoomLevel();
      _maxZoom = await camera.getMaxZoomLevel();
      if (generation != _generation) return;
      _zoom = _minZoom;
      _zoomAtGestureStart = _minZoom;
      await camera.setZoomLevel(_minZoom);
      // The other sensor has its own metering and its own range, so the
      // correction is applied again rather than assumed to have carried over.
      await _brighten(camera);
      await _logLens(camera);
      await camera.lockCaptureOrientation(DeviceOrientation.portraitUp);
    } catch (e) {
      error = '$e';
      DebugLog.instance.log('CIRCLE', 'flip failed: $e');
    } finally {
      _flipping = false;
      _notify();
    }
  }

  bool _flipping = false;

  /// Which way the open camera is pointing, so a flip knows what to ask for —
  /// and so the preview can turn over when it changes.
  bool _front = true;
  bool get isFront => _front;

  /// True once the preview has a picture in it. The ring is drawn against
  /// this rather than against [isRecording], so the circle does not appear as
  /// a black hole while the camera opens.
  ///
  /// **A sensor swap does not count as not-ready.** `setDescription` takes the
  /// controller through a moment where `isInitialized` is false, and the disc
  /// was drawn against this directly — so flipping the camera made the picture
  /// vanish and come back, on top of the turn animation that was there to
  /// cover exactly that gap. The controller is the same object throughout and
  /// its texture keeps showing the last frame, so holding it here is showing
  /// what the screen already has rather than pretending.
  bool get isReady =>
      _flipping ? _camera != null : (_camera?.value.isInitialized ?? false);

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
    if (_camera != null || _starting || _stopping || _disposed) return false;
    _starting = true;
    final generation = ++_generation;
    try {
      final cameras = await _listCameras();
      if (generation != _generation) return false;
      if (cameras.isEmpty) {
        error = 'no-camera';
        return false;
      }
      final wanted =
          front ? CameraLensDirection.front : CameraLensDirection.back;
      final lens = widestLens(cameras, wanted);

      // Keep the bounded recording budget from _makeCamera.
      final camera = _createCamera(lens);
      _camera = camera;
      _notify();
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
      await _brighten(camera);
      _torchOn = false;
      // A front camera has no flash on any phone this will meet, and asking
      // anyway is worse than not asking: the call succeeds and lights nothing.
      _hardwareTorch = lens.lensDirection == CameraLensDirection.back;
      _front = lens.lensDirection == CameraLensDirection.front;

      if (generation != _generation) return false;
      // Keep the preview's aspect ratio stable when a held phone tilts.
      await camera.lockCaptureOrientation(DeviceOrientation.portraitUp);
      if (generation != _generation) return false;
      await _logLens(camera);
      if (generation != _generation) return false;
      await camera.startVideoRecording(enablePersistentRecording: true);
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
        (_) => _notify(),
      );
      _ceiling = Timer(maxLength, () => onCeilingReached?.call());
      _notify();
      return true;
    } on CameraException catch (e) {
      // Told apart so the screen can say "circles need the camera and the
      // microphone" for a refusal and "could not record" for a camera that is
      // simply busy or broken. They read very differently to the person
      // holding the phone: one is a thing they can fix in Settings.
      final denied = _deniedCodes.contains(e.code);
      DebugLog.instance.log(
        'CIRCLE',
        'start failed: ${e.code} ${e.description ?? ''}'
            '${denied ? ' (access refused)' : ''}',
      );
      error = denied ? 'camera-or-microphone-denied' : '${e.code}';
      if (generation == _generation) await _release();
      return false;
    } catch (e) {
      DebugLog.instance.log('CIRCLE', 'start failed: $e');
      error = '$e';
      if (generation == _generation) await _release();
      return false;
    } finally {
      _starting = false;
    }
  }

  /// Invalidate pending permission/open/flip work immediately, even before a
  /// camera exists. Serialising the finish prevents two native stop requests.
  Future<({File file, Duration length})?> stop() => _finish(discard: false);

  Future<void> cancel() async {
    await _finish(discard: true);
  }

  Future<({File file, Duration length})?> _finish({required bool discard}) {
    final pending = _ending;
    if (pending != null) return pending;
    _generation++;
    _stopping = true;
    _notify();
    final operation = _finishCamera(discard: discard);
    _ending = operation;
    return operation;
  }

  Future<({File file, Duration length})?> _finishCamera({
    required bool discard,
  }) async {
    final camera = _camera;
    final length = elapsed;
    _ticker?.cancel();
    _ceiling?.cancel();
    try {
      await _lensChange;
      if (camera == null || !camera.value.isRecordingVideo) return null;
      final shot = await camera.stopVideoRecording();
      final file = File(shot.path);
      if (discard || length < minLength) {
        await _quietlyDelete(file);
        return null;
      }
      return (file: file, length: length);
    } catch (e) {
      DebugLog.instance.log('CIRCLE', 'finish failed: $e');
      return null;
    } finally {
      await _release();
      _stopping = false;
      _ending = null;
      _notify();
    }
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
    _notify();
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
    _disposed = true;
    unawaited(cancel());
    super.dispose();
  }
}
