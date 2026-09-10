# CubeChat patches to camera_avfoundation

## Field of view (2026-09-10)

`.veryHigh` picks a 4:3 capture format near 1080 on the short side before
falling back to the `.hd1920x1080` preset it always used. Only the round video
message uses that preset; the in-app photo camera is on `.high`.

A round window is a square cut from the middle, so it takes the frame's short
side: 1440x1080 and 1920x1080 put the same 1080 pixels on the disc, and a 16:9
frame's extra columns fall outside the circle. What differs is how much of the
room is in them, because a phone builds 16:9 by keeping the sensor's full width
and cutting its height, which in portrait is about a quarter narrower than the
native 4:3. The Android side does the same thing through CameraX's aspect-ratio
strategy; see the matching note in `third_party/camera_android_camerax`.

AVFoundation has no 4:3 session preset above VGA, so the format is chosen
directly with `.inputPriority` and `flutterActiveFormat`, exactly as `.max`
already does. The search is bounded at 1080 on the short side rather than
taking the largest 4:3 available: the largest is a twelve-megapixel stills
format on most iPhones, which the encoder would then scale down every frame for
a disc drawn at a few hundred points. A device with no 4:3 video format in
range falls through to the old preset.

## Camera frame rate on sensor changes

Vendored from Flutter camera_avfoundation 0.10.2 (BSD license in LICENSE).
Only DefaultCamera.swift changes: reuse the existing supported-format / nearest
frame-rate selection after switching cameras during a persistent recording.
Both initial and replacement cameras receive the 60 fps request; unsupported
formats retain AVFoundation's nearest supported rate. Existing native selfie
mirroring and video orientation are preserved.

Swift compilation and real sensor cadence must be checked on macOS/iOS.
