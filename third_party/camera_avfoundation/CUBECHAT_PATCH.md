# Camera frame rate on sensor changes

Vendored from Flutter camera_avfoundation 0.10.2 (BSD license in LICENSE).
Only DefaultCamera.swift changes: reuse the existing supported-format / nearest
frame-rate selection after switching cameras during a persistent recording.
Both initial and replacement cameras receive the 60 fps request; unsupported
formats retain AVFoundation's nearest supported rate. Existing native selfie
mirroring and video orientation are preserved.

Swift compilation and real sensor cadence must be checked on macOS/iOS.
