import 'dart:async';
import 'package:camera/camera.dart';
import 'package:cubechat/features/chat/data/circle_recorder.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const front = CameraDescription(
  name: 'front',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 90,
);
const back = CameraDescription(
  name: 'back',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);

class FakeCamera extends CameraController {
  FakeCamera(CameraDescription description)
      : super(description, ResolutionPreset.medium);
  int starts = 0;
  int stops = 0;
  int flips = 0;
  int stabilizations = 0;
  double? zoom;
  bool released = false;
  Completer<void>? changing;
  @override
  Future<void> initialize() async {
    value = value.copyWith(isInitialized: true);
  }

  @override
  Future<double> getMinZoomLevel() async => .5;
  @override
  Future<double> getMaxZoomLevel() async => 4;
  @override
  Future<void> setZoomLevel(double zoom) async {
    this.zoom = zoom;
  }

  @override
  Future<void> setVideoStabilizationMode(
    VideoStabilizationMode mode, {
    bool allowFallback = true,
  }) async {
    stabilizations++;
    value = value.copyWith(videoStabilizationMode: mode);
  }

  @override
  Future<void> setFlashMode(FlashMode mode) async {}
  @override
  Future<void> lockCaptureOrientation([DeviceOrientation? orientation]) async {}
  @override
  Future<void> startVideoRecording({
    onLatestImageAvailable? onAvailable,
    bool enablePersistentRecording = true,
  }) async {
    starts++;
    value = value.copyWith(isRecordingVideo: true);
  }

  @override
  Future<XFile> stopVideoRecording() async {
    stops++;
    value = value.copyWith(isRecordingVideo: false);
    return XFile('missing-test-clip.mp4');
  }

  @override
  Future<void> setDescription(CameraDescription description) async {
    flips++;
    await changing?.future;
    value = value.copyWith(description: description);
  }

  // No platform camera was initialized by this fake, and CameraController's
  // own dispose() goes straight to the platform channel — so super is the one
  // thing this must not call.
  //
  // The ignore sits *under* the annotation deliberately. A `// ignore:`
  // comment applies to the line after it and `@override` is a line, so with
  // the comment above the annotation the suppression lands on nothing and the
  // warning still fires. That is what turned the Android CI gate red from
  // build 1008 to 1010: analyze passes locally as an info-only tree, and the
  // one warning in it fails the grep the workflow gates on.
  @override
  // ignore: must_call_super
  Future<void> dispose() async {
    released = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('widest facing you, main lens facing away', () {
    // Two different questions wearing one name. An ultra-wide is the only way
    // to get more than a face into a disc held at arm's length, so facing you
    // it wins. Facing away it loses: a phone's ultra-wide is its cheapest
    // sensor, smaller and softer than the main one, and somebody pointing the
    // camera at a subject wants the sharp lens, not the roomy one. Reported as
    // "the rear camera is not sharp" after the front-facing rule was applied
    // to both.
    const ultraBack = CameraDescription(
      name: 'ultra',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 90,
      lensType: CameraLensType.ultraWide,
    );
    const wideBack = CameraDescription(
      name: 'wide',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 90,
      lensType: CameraLensType.wide,
    );
    const teleBack = CameraDescription(
      name: 'tele',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 90,
      lensType: CameraLensType.telephoto,
    );
    const ultraFront = CameraDescription(
      name: 'ultra-front',
      lensDirection: CameraLensDirection.front,
      sensorOrientation: 90,
      lensType: CameraLensType.ultraWide,
    );

    expect(
      CircleRecorder.widestLens(
        [front, wideBack, ultraBack, teleBack],
        CameraLensDirection.back,
      ),
      wideBack,
      reason: 'the main lens, not the ultra-wide and not the telephoto',
    );
    expect(
      CircleRecorder.widestLens(
        [front, ultraFront],
        CameraLensDirection.front,
      ),
      ultraFront,
      reason: 'facing you, wider is the whole point',
    );
    expect(
      CircleRecorder.widestLens(
        [front, back, ultraBack],
        CameraLensDirection.back,
      ),
      back,
      reason: 'Android reports every lens as unknown, and the unknown one is '
          'the camera the platform listed first — still a better guess than '
          'an ultra-wide that admitted what it was',
    );
  });
  test('cancel while the camera list is pending prevents the camera opening',
      () async {
    // Was "while permission is pending", back when the recorder asked
    // permission_handler before opening anything. It no longer does — that
    // request was compiled out on iOS and refused every circle there — so the
    // first await inside start() is now the camera list. Same property under
    // test: letting go during an await that outlasts the finger must not open
    // a camera afterwards.
    final cameras = Completer<List<CameraDescription>>();
    var created = 0;
    final recorder = CircleRecorder(
      listCameras: () => cameras.future,
      createCamera: (lens) {
        created++;
        return FakeCamera(lens);
      },
    );
    addTearDown(() async {
      await recorder.cancel();
    });
    final starting = recorder.start();
    await recorder.cancel();
    cameras.complete([front, back]);
    expect(await starting, false);
    expect(created, 0);
    await recorder.cancel();
    recorder.dispose();
  });

  test('a refused camera is reported as a refusal, not as a broken camera',
      () async {
    // The camera plugin asks for camera and microphone itself now, and says no
    // by throwing. Mapping the code is what puts "circles need the camera and
    // microphone" on screen instead of a raw platform string.
    final recorder = CircleRecorder(
      listCameras: () async => [front],
      createCamera: (_) => _RefusingCamera(front),
    );
    expect(await recorder.start(), false);
    expect(recorder.error, 'camera-or-microphone-denied');
    expect(recorder.isActive, false);
    recorder.dispose();
  });

  test('a camera that fails for another reason is not called a refusal',
      () async {
    final recorder = CircleRecorder(
      listCameras: () async => [front],
      createCamera: (_) => _RefusingCamera(front, code: 'CameraNotFound'),
    );
    expect(await recorder.start(), false);
    expect(recorder.error, 'CameraNotFound');
    recorder.dispose();
  });
  test('flip keeps the current recording and never discards its file',
      () async {
    final camera = FakeCamera(front);
    final recorder = CircleRecorder(
      listCameras: () async => [front, back],
      createCamera: (_) => camera,
    );
    addTearDown(() async {
      await recorder.cancel();
    });
    expect(await recorder.start(), true);
    await recorder.flipLens();
    expect(camera.flips, 1);
    // Never asked for, on either lens. Electronic stabilisation buys steadiness
    // by keeping a margin of frame in hand to shift into, which is a crop of
    // about a tenth — and it went in during the same round that "the picture is
    // too close in" came back, on a recorder already pinned to the lens
    // minimum. See the comment on `_logLens` for the crop that is left and why
    // undoing that one costs the resolution.
    expect(camera.stabilizations, 0);
    expect(camera.zoom, .5);
    expect(camera.stops, 0);
    expect(camera.starts, 1);
    expect(recorder.isFront, false);
    expect(recorder.isRecording, true);
    await recorder.cancel();
    recorder.dispose();
  });
  test('cancel waits for a sensor switch then stops once without restarting',
      () async {
    final camera = FakeCamera(front);
    final recorder = CircleRecorder(
      listCameras: () async => [front, back],
      createCamera: (_) => camera,
    );
    await recorder.start();
    camera.changing = Completer<void>();
    final flipping = recorder.flipLens();
    await Future<void>.delayed(Duration.zero);
    final cancelling = recorder.cancel();
    final cancellingAgain = recorder.cancel();
    camera.changing!.complete();
    await Future.wait([flipping, cancelling, cancellingAgain]);
    expect(camera.stops, 1);
    expect(camera.starts, 1);
    expect(camera.released, true);
    expect(recorder.isActive, false);
    expect(recorder.isFlipping, false);
    recorder.dispose();
  });

  test('release while the camera list is pending prevents a late recording',
      () async {
    final cameras = Completer<List<CameraDescription>>();
    final recorder = CircleRecorder(
      listCameras: () => cameras.future,
      createCamera: (_) => FakeCamera(front),
    );
    final starting = recorder.start();
    expect(await recorder.stop(), isNull);
    cameras.complete([front]);
    expect(await starting, false);
    expect(recorder.isActive, false);
    recorder.dispose();
  });
}

/// A camera that refuses to open, the way one does when the person says no to
/// the system dialog the plugin puts up.
class _RefusingCamera extends CameraController {
  _RefusingCamera(
    CameraDescription description, {
    this.code = 'CameraAccessDenied',
  }) : super(description, ResolutionPreset.medium);

  final String code;

  @override
  Future<void> initialize() async {
    throw CameraException(code, 'refused by the test');
  }

  // Nothing native was opened, so there is nothing to hand back.
  @override
  // ignore: must_call_super
  Future<void> dispose() async {}
}
