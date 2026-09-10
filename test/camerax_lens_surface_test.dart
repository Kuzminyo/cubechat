import 'dart:async';

import 'package:camera_android_camerax/camera_android_camerax.dart';
import 'package:camera_android_camerax/src/camerax_library.dart';
import 'package:camera_android_camerax/src/rotated_preview_delegate.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// A fake stands in for a pigeon proxy, and those are `@immutable`; counting the
// calls a fake receives is the whole point of one. Same for `_Provider` below.
// ignore: must_be_immutable
class _Preview extends Fake implements Preview {
  int texture = 40;
  int releases = 0;
  @override
  Future<int> setSurfaceProvider(SystemServicesManager manager) async => ++texture;
  @override
  Future<void> releaseSurfaceProvider() async { releases++; }
  @override
  Future<bool> surfaceProducerHandlesCropAndRotation() async => false;
}
class _Services extends Fake implements SystemServicesManager {
  @override
  Future<CameraPermissionsError?> requestCameraPermissions(bool audio) async => null;
}
class _Orientation extends Fake implements DeviceOrientationManager {
  @override
  Future<void> startListeningForDeviceOrientationChange() async {}
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
class _Control extends Fake implements CameraControl {}
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
  final info = _Info();
  @override
  final CameraControl cameraControl = _Control();
  @override
  Future<CameraInfo> getCameraInfo() async => info;
}
// ignore: must_be_immutable
class _Provider extends Fake implements ProcessCameraProvider {
  final binds = <List<UseCase>>[];
  Completer<void>? binding;
  @override
  Future<void> unbindAll() async {}
  @override
  Future<bool> isBound(UseCase useCase) async => false;
  @override
  Future<Camera> bindToLifecycle(CameraSelector selector, List<UseCase> cases) async {
    binds.add(cases);
    await binding?.future;
    return _Camera();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    PigeonOverrides.pigeon_reset();
    GenericsPigeonOverrides.reset();
  });
  test('sensor swap never applies new rotation to the old sensor texture', () async {
    final preview = _Preview();
    final provider = _Provider();
    final video = _Video();
    PigeonOverrides.preview_new = ({resolutionSelector, targetRotation, targetFpsRange}) => preview;
    PigeonOverrides.systemServicesManager_new = ({required onCameraError}) => _Services();
    PigeonOverrides.deviceOrientationManager_new = ({required onDeviceOrientationChanged}) => _Orientation();
    PigeonOverrides.cameraSelector_new = ({requireLensFacing, cameraInfoForFilter}) => _Selector();
    PigeonOverrides.imageCapture_new = ({flashMode, resolutionSelector, targetRotation}) => _Still();
    PigeonOverrides.recorder_new = ({aspectRatio, qualitySelector, targetVideoEncodingBitRate}) => _Recorder();
    PigeonOverrides.videoCapture_withOutput = ({required videoOutput, targetFpsRange}) => video;
    GenericsPigeonOverrides.observerNew = <T>({required void Function(Observer<T>, T) onChanged}) => Observer<T>.detached(onChanged: onChanged);
    final camera = AndroidCameraCameraX()..processCameraProvider = provider;
    const front = CameraDescription(name: 'front', lensDirection: CameraLensDirection.front, sensorOrientation: 270);
    const back = CameraDescription(name: 'back', lensDirection: CameraLensDirection.back, sensorOrientation: 90);
    final id = await camera.createCameraWithSettings(front, null);
    camera.previewInitiallyBound = true;
    final recording = _Recording();
    camera.recording = recording;
    // The delegate is the plugin's own internal widget, and reaching into it is
    // the point: what is asserted here is which texture it was handed and which
    // correction it was given, which nothing public exposes.
    // ignore: invalid_use_of_internal_member
    RotatedPreviewDelegate shown() => camera.buildPreview(id) as RotatedPreviewDelegate;
    int texture() => (shown().child as Texture).textureId;
    final original = texture();
    provider.binding = Completer<void>();
    final flip = camera.setDescriptionWhileRecording(back);
    await Future<void>.delayed(Duration.zero);
    expect(texture(), original, reason: 'keep old frame and correction paired while binding');
    expect(shown().sensorOrientationDegrees, 270);
    provider.binding!.complete();
    await flip;
    final rearTexture = texture();
    expect(rearTexture, isNot(original), reason: 'front pixels must not be rotated as rear pixels');
    expect(shown().sensorOrientationDegrees, 90);
    expect(shown().cameraIsFrontFacing, isFalse);
    expect(camera.recording, same(recording));
    expect(provider.binds.single, contains(same(video)));
    await camera.setDescriptionWhileRecording(front);
    expect(texture(), isNot(rearTexture));
    expect(shown().sensorOrientationDegrees, 270);
    expect(shown().cameraIsFrontFacing, isTrue);
    expect(preview.releases, 2, reason: 'old surfaces must be released');
    expect(camera.recording, same(recording));
  });
}
