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
  bool released = false;
  Completer<void>? changing;
  @override
  Future<void> initialize() async {
    value = value.copyWith(isInitialized: true);
  }

  @override
  Future<double> getMinZoomLevel() async => 1;
  @override
  Future<double> getMaxZoomLevel() async => 4;
  @override
  Future<void> setZoomLevel(double zoom) async {}
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

  // No platform camera was initialized by this fake.
  // ignore: must_call_super
  @override
  Future<void> dispose() async {
    released = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('cancel while permission is pending prevents the camera opening',
      () async {
    final permission = Completer<bool>();
    var created = 0;
    final recorder = CircleRecorder(
      requestAccess: () => permission.future,
      listCameras: () async => [front, back],
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
    permission.complete(true);
    expect(await starting, false);
    expect(created, 0);
    await recorder.cancel();
    recorder.dispose();
  });
  test('flip keeps the current recording and never discards its file',
      () async {
    final camera = FakeCamera(front);
    final recorder = CircleRecorder(
      requestAccess: () async => true,
      listCameras: () async => [front, back],
      createCamera: (_) => camera,
    );
    addTearDown(() async {
      await recorder.cancel();
    });
    expect(await recorder.start(), true);
    await recorder.flipLens();
    expect(camera.flips, 1);
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
      requestAccess: () async => true,
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

  test('release while permissions are pending prevents a late recording',
      () async {
    final permission = Completer<bool>();
    final recorder = CircleRecorder(
      requestAccess: () => permission.future,
      listCameras: () async => [front],
      createCamera: (_) => FakeCamera(front),
    );
    final starting = recorder.start();
    expect(await recorder.stop(), isNull);
    permission.complete(true);
    expect(await starting, false);
    expect(recorder.isActive, false);
    recorder.dispose();
  });
}
