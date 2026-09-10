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

Field of view (2026-09-10): `ResolutionPreset.veryHigh` now asks for 4:3 at
1440x1080 instead of 16:9 at 1920x1080, and the Recorder is told the same
aspect ratio because CameraX qualities are 16:9 by definition and would
otherwise record a different shape than the preview showed. Only the round
video message uses this preset; the in-app photo camera is on `high` and is
untouched.

It costs nothing. A round window is a square cut from the middle, so it takes
the frame's short side: both modes put 1080 pixels on the disc, and a 16:9
frame's extra 480 columns fall outside the circle and are encoded for nothing.
What changes is how much of the room is in those pixels — a phone builds 16:9
by keeping the sensor's full width and cutting its height, which in portrait is
about a quarter narrower than the native 4:3. Compared side by side against
Telegram's round video on the same phone: theirs showed the shoulders, ours
stopped at the jaw. `AspectRatioStrategy` keeps `fallbackRule: auto`, so a
sensor with no 4:3 video mode gets the nearest thing rather than failing.

Camera selection: ProcessCameraProvider orders only its exposed cameras by
sensor short edge / focal length / minimum logical zoom. Android descriptions
otherwise all report unknown lens type, so a Dart lens preference alone cannot
choose the widest view. Missing Camera2 metadata preserves relative order.
This removes an arbitrary sensor choice; it cannot widen a single fixed lens.
