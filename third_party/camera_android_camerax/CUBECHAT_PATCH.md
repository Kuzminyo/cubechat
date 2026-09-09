# CubeChat camera patch

Source: Flutter camera_android_camerax 0.7.2 from the installed pub package. BSD license retained in LICENSE. Runtime lib/ and android/ are vendored; example and Dart generator tooling are not needed by the application.

Only functional patch: VideoCaptureProxyApi sets MirrorMode.MIRROR_MODE_ON_FRONT_ONLY. This mirrors the encoded front-camera video, including persistent recordings that switch sensors, while keeping rear-camera footage normal. Preview mirroring is already handled by CameraX. No second Dart transform is applied.

The VideoCaptureTest asserts the capture mode. To upgrade, update the vendored package and reapply this small patch. iOS camera_avfoundation 0.10.2 already sets isVideoMirrored on the front video-data connection used by the preview and writer.

CameraX API reference: https://developer.android.com/reference/androidx/camera/video/VideoCapture.Builder#setMirrorMode(int)
