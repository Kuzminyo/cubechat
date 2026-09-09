# CubeChat camera patch

Source: Flutter camera_android_camerax 0.7.2 from the installed pub package. BSD license retained in LICENSE. Runtime lib/ and android/ are vendored; example and Dart generator tooling are not needed by the application.

Only functional patch: VideoCaptureProxyApi sets MirrorMode.MIRROR_MODE_ON_FRONT_ONLY. This mirrors the encoded front-camera video, including persistent recordings that switch sensors, while keeping rear-camera footage normal. Preview mirroring is already handled by CameraX. No second Dart transform is applied.

The VideoCaptureTest asserts the capture mode. To upgrade, update the vendored package and reapply this small patch. iOS camera_avfoundation 0.10.2 already sets isVideoMirrored on the front video-data connection used by the preview and writer.

CameraX API reference: https://developer.android.com/reference/androidx/camera/video/VideoCapture.Builder#setMirrorMode(int)

Preview correction now uses the locked capture orientation, matching CameraPreview,
rather than subtracting the live device orientation during a portrait recording.
Correction state is keyed by sensor and orientation lock so a lens swap cannot
retain the previous sensor's correction. Front mirroring remains native.

60 fps uses Preview/VideoCapture.setTargetFrameRate instead of forcing a raw
Camera2 AE range, allowing CameraX to negotiate a supported rate at each bind.
The unused high-FPS analysis stream no longer overrides the negotiated rate.
Dart now forwards MediaSettings.videoBitrate to the native Recorder as intended.
See https://developer.android.com/reference/androidx/camera/video/VideoCapture.Builder#setTargetFrameRate(android.util.Range%3Cjava.lang.Integer%3E).

Camera selection: ProcessCameraProvider orders only its exposed cameras by
sensor short edge / focal length / minimum logical zoom. Android descriptions
otherwise all report unknown lens type, so a Dart lens preference alone cannot
choose the widest view. Missing Camera2 metadata preserves relative order.
This removes an arbitrary sensor choice; it cannot widen a single fixed lens.
