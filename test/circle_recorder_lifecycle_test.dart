import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:cubechat/features/chat/data/circle_recorder.dart';
import 'package:fake_async/fake_async.dart';
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
  int disposals = 0;
  int exposureWrites = 0;
  bool refuseTorch = false;
  Completer<void>? opening;
  Completer<void>? starting;
  Completer<void>? exposure;
  Completer<void>? changing;
  Completer<void>? stopping;
  Completer<void>? disposing;
  @override
  Future<void> initialize() async {
    await opening?.future;
    value = value.copyWith(isInitialized: true);
  }

  @override
  Future<double> getMinZoomLevel() async => .5;
  @override
  Future<double> getMinExposureOffset() async {
    await exposure?.future;
    return 0;
  }

  @override
  Future<double> getMaxExposureOffset() async => 2;
  @override
  Future<double> setExposureOffset(double offset) async {
    exposureWrites++;
    return offset;
  }

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
  Future<void> setFlashMode(FlashMode mode) async {
    if (refuseTorch && mode == FlashMode.torch) {
      throw CameraException('torchUnavailable', 'No flash unit');
    }
  }

  @override
  Future<void> lockCaptureOrientation([DeviceOrientation? orientation]) async {}
  @override
  Future<void> startVideoRecording({
    onLatestImageAvailable? onAvailable,
    bool enablePersistentRecording = true,
  }) async {
    starts++;
    await starting?.future;
    value = value.copyWith(isRecordingVideo: true);
  }

  @override
  Future<XFile> stopVideoRecording() async {
    stops++;
    await stopping?.future;
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
    disposals++;
    await disposing?.future;
    released = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('rear flash failure never pretends a screen light illuminates the scene',
      () async {
    final camera = FakeCamera(back)..refuseTorch = true;
    final recorder = CircleRecorder(
        listCameras: () async => [back], createCamera: (_) => camera);
    await recorder.start(front: false);
    await recorder.toggleTorch();
    expect(recorder.torchOn, isFalse);
    expect(recorder.usesScreenLight, isFalse);
    await recorder.cancel();
    recorder.dispose();
  });
  for (final duringStart in [false, true]) {
    test(
        'cancel waits for native ${duringStart ? 'recording start' : 'initialization'} before disposal',
        () async {
      final gate = Completer<void>();
      final camera = FakeCamera(front);
      if (duringStart) {
        camera.starting = gate;
      } else {
        camera.opening = gate;
      }
      final recorder = CircleRecorder(
        listCameras: () async => [front, back],
        createCamera: (_) => camera,
      );
      final start = recorder.start();
      await Future<void>.delayed(Duration.zero);
      final cancel = recorder.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(
        camera.released,
        isFalse,
        reason: 'native calls must not race dispose',
      );
      gate.complete();
      expect(await start, isFalse);
      await cancel;
      expect(camera.disposals, 1);
      expect(camera.stops, duringStart ? 1 : 0);
      expect(recorder.isActive, isFalse);
      recorder.dispose();
    });
  }
  test('recording starts before optional exposure queries complete', () async {
    final camera = FakeCamera(front)..exposure = Completer<void>();
    final recorder = CircleRecorder(
      listCameras: () async => [front, back],
      createCamera: (_) => camera,
    );
    final start = recorder.start();
    await Future<void>.delayed(Duration.zero);
    expect(camera.starts, 1);
    camera.exposure!.complete();
    expect(await start, isTrue);
    await recorder.cancel();
    recorder.dispose();
  });

  test('cancel prevents a late exposure write and a fresh recording can start',
      () async {
    final first = FakeCamera(front)..exposure = Completer<void>();
    final second = FakeCamera(front);
    var created = 0;
    final recorder = CircleRecorder(
      listCameras: () async => [front, back],
      createCamera: (_) => created++ == 0 ? first : second,
    );
    expect(await recorder.start(), isTrue);
    await recorder.cancel();
    expect(await recorder.start(), isTrue);
    first.exposure!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(first.exposureWrites, 0);
    expect(first.disposals, 1);
    expect(second.starts, 1);
    expect(second.released, isFalse);
    await recorder.cancel();
    recorder.dispose();
  });

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
    // **1.0 on the back, though the fake reports a minimum of 0.5.**
    //
    // A modern phone presents its rear cameras as one logical device whose
    // range starts at 0.5, and that half is the ultra-wide. Opening there is
    // right facing you — fitting more than a face into a disc at arm's length
    // is the whole difficulty of a selfie — and wrong facing away, where 1.0 is
    // the main lens's own framing and the sharpest thing the phone has.
    // Reported as the rear camera sitting at half zoom by default.
    expect(camera.zoom, 1.0);
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

  group('a camera that never answers does not end circles for good', () {
    // "Sometimes a circle just freezes." Every stop waits on native calls —
    // the start still in flight, the mp4 being finalised, the camera being
    // released — and a stop that never finishes holds the screen's finishing
    // gate shut, so no circle can start again until the app is killed. These
    // calls are bounded now: a wedged camera costs one lost clip and a log
    // line, not every circle after it.
    test('a stop that never returns still releases the camera', () {
      fakeAsync((async) {
        final first = FakeCamera(front)..stopping = Completer<void>();
        final second = FakeCamera(front);
        var made = 0;
        final recorder = CircleRecorder(
          listCameras: () async => [front],
          createCamera: (_) => made++ == 0 ? first : second,
        );
        bool? started;
        recorder.start().then((ok) => started = ok);
        async.flushMicrotasks();
        expect(started, isTrue);

        ({File file, Duration length})? shot =
            (file: File('x'), length: Duration.zero);
        var stopped = false;
        recorder.stop().then((s) {
          shot = s;
          stopped = true;
        });
        async.elapse(
            CircleRecorder.nativeCallCeiling - const Duration(milliseconds: 1));
        expect(stopped, isFalse, reason: 'not a moment early');
        async.elapse(const Duration(milliseconds: 2));
        async.flushMicrotasks();
        expect(stopped, isTrue);
        expect(shot, isNull, reason: 'no finished file came back to send');
        expect(first.released, isTrue);
        expect(recorder.isActive, isFalse);

        bool? again;
        recorder.start().then((ok) => again = ok);
        async.flushMicrotasks();
        expect(again, isTrue, reason: 'the next circle is not locked out');
        recorder.cancel();
        async.flushMicrotasks();
        recorder.dispose();
      });
    });

    // The worst camera there is: it never finishes opening, and once asked to
    // let go it never finishes that either. The open that never returns is
    // the dangerous half — the recorder's "a start is in progress" flag was
    // only cleared when that start returned, so even after the cancel had
    // released everything, every later circle was refused as "already
    // starting", for as long as the app stayed open.
    test(
        'a camera that never opens and never lets go does not lock circles out',
        () {
      fakeAsync((async) {
        final first = FakeCamera(front)
          ..opening = Completer<void>()
          ..disposing = Completer<void>();
        final second = FakeCamera(front);
        var made = 0;
        final recorder = CircleRecorder(
          listCameras: () async => [front],
          createCamera: (_) => made++ == 0 ? first : second,
        );
        recorder.start();
        async.flushMicrotasks();
        expect(recorder.isActive, isTrue, reason: 'stuck opening');

        var stopped = false;
        recorder.cancel().then((_) => stopped = true);
        // One ceiling for the open it gave up on, one for the release.
        async.elapse(CircleRecorder.nativeCallCeiling * 2 +
            const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(stopped, isTrue);
        expect(recorder.isActive, isFalse);

        bool? again;
        recorder.start().then((ok) => again = ok);
        async.flushMicrotasks();
        expect(again, isTrue);
        recorder.cancel();
        async.flushMicrotasks();
        recorder.dispose();
      });
    });
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
