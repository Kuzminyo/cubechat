import 'dart:async';

import 'package:camera_android_camerax/camera_android_camerax.dart';
import 'package:camera_android_camerax/src/camerax_library.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The vendored CameraX plugin's torch, and the order a lens swap does its
/// work in.
///
/// Both were reported from a phone in one message: the torch on the back camera
/// did not light, and switching cameras was slow.
///
/// The torch: the plugin keeps one "torch is on" flag for the whole app — its
/// platform instance is a singleton — and set it to true even when enabling
/// failed, and never cleared it when a camera was released or swapped. Record a
/// circle with the torch on, and the next circle's torch was a no-op, because
/// the plugin believed it was already lit.
///
/// The swap: a new preview surface was set on a Preview that was already
/// bound, and CameraX answers that by rebuilding the whole capture session — a
/// second time, straight after the bind had just built it. Setting the surface
/// while nothing is bound makes the bind the only rebuild.
final List<String> events = [];

// A fake stands in for a pigeon proxy, and those are `@immutable`; a fake that
// counts what it is asked is the point of one. Same for `_Control` below.
// ignore: must_be_immutable
class _Preview extends Fake implements Preview {
  int texture = 40;
  @override
  Future<int> setSurfaceProvider(SystemServicesManager manager) async {
    events.add('setSurface');
    return ++texture;
  }

  @override
  Future<void> releaseSurfaceProvider() async => events.add('releaseSurface');
  @override
  Future<bool> surfaceProducerHandlesCropAndRotation() async => false;
}

class _Services extends Fake implements SystemServicesManager {
  @override
  Future<CameraPermissionsError?> requestCameraPermissions(bool audio) async =>
      null;
}

class _Orientation extends Fake implements DeviceOrientationManager {
  @override
  Future<void> startListeningForDeviceOrientationChange() async {}
  @override
  Future<void> stopListeningForDeviceOrientationChange() async {}
  @override
  Future<int> getDefaultDisplayRotation() async => 0;
  @override
  Future<String> getUiOrientation() async => 'PORTRAIT_UP';
}

class _Still extends Fake implements ImageCapture {}

class _Video extends Fake implements VideoCapture {}

class _Recorder extends Fake implements Recorder {}

class _Recording extends Fake implements Recording {}

class _Selector extends Fake implements CameraSelector {}

// ignore: must_be_immutable
class _Control extends Fake implements CameraControl {
  final List<bool> torches = [];
  bool failNext = false;
  @override
  Future<void> enableTorch(bool torch) async {
    torches.add(torch);
    if (failNext) {
      failNext = false;
      throw PlatformException(code: 'CameraControl', message: 'cancelled');
    }
  }
}

class _State extends Fake implements LiveData<CameraState> {
  @override
  Future<void> removeObservers() async {}
  @override
  Future<void> observe(Observer<CameraState> observer) async {}
}

class _Info extends Fake implements CameraInfo {
  final state = _State();
  @override
  Future<LiveData<CameraState>> getCameraState() async => state;
}

class _Camera extends Fake implements Camera {
  _Camera(this.cameraControl);
  final info = _Info();
  @override
  final CameraControl cameraControl;
  @override
  Future<CameraInfo> getCameraInfo() async => info;
}

class _Provider extends Fake implements ProcessCameraProvider {
  final controls = <_Control>[];
  @override
  Future<void> unbindAll() async => events.add('unbind');
  @override
  Future<bool> isBound(UseCase useCase) async => false;
  @override
  Future<Camera> bindToLifecycle(
      CameraSelector selector, List<UseCase> cases) async {
    events.add('bind');
    final control = _Control();
    controls.add(control);
    return _Camera(control);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Provider provider;
  late AndroidCameraCameraX camera;
  late _Control first;
  const front = CameraDescription(
      name: 'front',
      lensDirection: CameraLensDirection.front,
      sensorOrientation: 270);
  const back = CameraDescription(
      name: 'back',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 90);

  setUp(() async {
    events.clear();
    provider = _Provider();
    PigeonOverrides.preview_new =
        ({resolutionSelector, targetRotation, targetFpsRange}) => _Preview();
    PigeonOverrides.systemServicesManager_new =
        ({required onCameraError}) => _Services();
    PigeonOverrides.deviceOrientationManager_new =
        ({required onDeviceOrientationChanged}) => _Orientation();
    PigeonOverrides.cameraSelector_new =
        ({requireLensFacing, cameraInfoForFilter}) => _Selector();
    PigeonOverrides.imageCapture_new =
        ({flashMode, resolutionSelector, targetRotation}) => _Still();
    PigeonOverrides.recorder_new =
        ({aspectRatio, qualitySelector, targetVideoEncodingBitRate}) =>
            _Recorder();
    PigeonOverrides.videoCapture_withOutput =
        ({required videoOutput, targetFpsRange}) => _Video();
    GenericsPigeonOverrides.observerNew =
        <T>({required void Function(Observer<T>, T) onChanged}) =>
            Observer<T>.detached(onChanged: onChanged);
    camera = AndroidCameraCameraX()..processCameraProvider = provider;
    await camera.createCameraWithSettings(back, null);
    first = _Control();
    camera.cameraControl = first;
    camera.previewInitiallyBound = true;
  });

  tearDown(() {
    PigeonOverrides.pigeon_reset();
    GenericsPigeonOverrides.reset();
  });

  group('torch', () {
    test('a torch that failed to light is asked again, not assumed lit', () async {
      first.failNext = true;
      await camera.setFlashMode(0, FlashMode.torch);
      await camera.setFlashMode(0, FlashMode.torch);
      expect(first.torches, [true, true],
          reason: 'the second press must reach the camera; the first never lit');
    });

    test('a released camera does not leave the next one believing it is lit',
        () async {
      await camera.setFlashMode(0, FlashMode.torch);
      expect(first.torches, [true]);
      await camera.dispose(0);

      await camera.createCameraWithSettings(back, null);
      final second = _Control();
      camera.cameraControl = second;
      await camera.setFlashMode(0, FlashMode.torch);
      expect(second.torches, [true],
          reason: 'a new camera starts dark, whatever the last one was doing');
    });

    test('a swapped lens does not inherit the old lens being lit', () async {
      await camera.setFlashMode(0, FlashMode.torch);
      camera.recording = _Recording();
      await camera.setDescriptionWhileRecording(front);
      await camera.setDescriptionWhileRecording(back);
      final current = provider.controls.last;
      await camera.setFlashMode(0, FlashMode.torch);
      expect(current.torches, [true]);
    });
  });

  test('a lens swap builds the capture session once, not twice', () async {
    camera.recording = _Recording();
    events.clear();
    await camera.setDescriptionWhileRecording(front);
    expect(events.where((e) => e == 'bind'), hasLength(1));
    expect(events.indexOf('setSurface'), lessThan(events.indexOf('bind')),
        reason: 'a surface set on a bound preview rebuilds the session again');
    expect(events.indexOf('unbind'), lessThan(events.indexOf('setSurface')),
        reason: 'and it must be unbound when the surface is set');
    expect(events.indexOf('releaseSurface'), lessThan(events.indexOf('setSurface')),
        reason: 'release first, or the old producer leaks');
  });
}
