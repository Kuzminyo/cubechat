# CubeChat patches to flutter_webrtc 0.12.12+hotfix.1

## No private `RPSystemBroadcastPickerView buttonPressed:` (2026-09-24)

App Review rejected build 1080 under guideline 2.5.1 for referencing
`RPSystemBroadcastPickerView.buttonPressed:`. Upstream's
`FlutterRTCDesktopCapturer.m` opened the iOS screen-broadcast picker by
performing that private selector. cubechat has voice calls only — no screen
sharing — so nothing ever asks for the picker; the block now only logs.
Patched in both `ios/Classes/` (what the podspec builds) and
`common/darwin/Classes/` (upstream's shared source).

Why not upgrade instead: 1.x no longer has the call, but a major version of the
WebRTC plugin under working calls is a far larger change than two deleted
lines, and calls can only be verified on two live phones.

## Trimmed to Android and iOS

The pub package carries a 97 MB prebuilt libwebrtc for Windows/Linux
(`third_party/`) plus macOS, elinux and example trees. The app ships on Android
and iOS only, so those trees are removed and `pubspec.yaml` declares only
`android` and `ios`. On a desktop build `flutter_webrtc` is simply absent —
calls there would throw MissingPluginException, and there are no calls there.

## Windows back (2026-10-12)

Calls on a Windows computer (docs/superpowers/specs/2026-10-12-desktop-calls-design.md).
Copied unchanged from the pub cache's `flutter_webrtc-0.12.12+hotfix.1`:

- `windows/` — the plugin's own CMake and C++ (9 KB);
- `third_party/uuidxx`, `third_party/svpng` — sources the plugin compiles;
- `third_party/libwebrtc/include` — headers;
- `third_party/libwebrtc/lib/win64` — `libwebrtc.dll` (18 MB) and its import
  library.

`pubspec.yaml` declares `windows` again. Linux, elinux and macOS stay out, with
the other ~79 MB of prebuilt libraries: only Windows has calls among the
desktops (`PlatformCapabilities.windows`). The DLL is committed, like
`windows/opus/libopus_x64.dll`, so a build needs no pub cache and CI fetches
nothing. `common/cpp` was already here and is identical to upstream's.

## Upgrading

Take the new version from the pub cache, reapply all three changes (including
the Windows tree above, from the new version), and check:

```bash
grep -rn "NSSelectorFromString(@\"buttonPressed" third_party/flutter_webrtc
```

must print nothing.
