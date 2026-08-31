---
name: release-build
description: How to build, version and ship a cubechat APK or IPA on this machine. Load when the task involves building a release, producing an APK or IPA for a tester, bumping the version or build stamp, installing on a phone, an "App not installed" failure, a signing fingerprint, the GitHub Actions workflows, or the Google Maps key.
user-invocable: true
---

# Building and shipping cubechat

## Build with the script for your platform, never bare `flutter build apk`

There are two scripts because the two machines fail differently. Both do the
same two things that matter, and neither is optional: cross-check the version
against `app_build.dart`, and prove the build stamp reached `libapp.so`.

```bash
tool/build_apk.sh                              # macOS / Linux
```

```bash
powershell -ExecutionPolicy Bypass -File tool/build_apk.ps1    # Windows
```

Flags are the same idea on both — `--clean` / `-Clean`, `--skip-pub-get` /
`-SkipPubGet`, `--bundle` / `-Bundle` for the AAB Play requires. The bash one
adds `--arm64`, which is a third the size and what testers are actually handed.

### On Windows, `flutter build apk` is genuinely broken and the error lies

Every `flutter pub get` — and every `analyze`, `test` and `build`, each of which
runs one — writes `.flutter-plugins-dependencies` with **double-escaped** paths:
the JSON holds `\\\\` where it should hold `\\`, so the parsed value is
`C:\\Users\\kuzme\\…` instead of `C:\Users\kuzme\…`.

Gradle's plugin loader then does `File(path, "android").exists()`, gets false,
and the build dies in about two seconds with:

```
Plugin directory does not exist: ...\geocoding_android-5.0.2\android
```

That path **does** exist, and the message prints it normalised, which makes it
look like a corrupt pub cache. It is not. Do not reinstall packages, do not run
`pub cache repair`. `build_apk.ps1` repairs the file and invokes Gradle directly,
because going through `flutter build` would rewrite it broken again.

### On macOS that fault does not exist, and a different one does

A path made of forward slashes has nothing to double-escape. Verified rather
than assumed on 2026-08-31: `pub get` and `flutter build apk` each rewrote the
file with plain `/Users/...` paths, zero occurrences of `\\\\`, and the build
ran through to a signed 33.4 MB arm64 APK in 895 s. So `build_apk.sh` drops the
repair, the plugin-directory check and the `local.properties` pinning — that
last one because `flutter build` calls `updateLocalProperties()` itself and
writes `flutter.versionName` / `versionCode` straight from pubspec, leaving
`GOOGLE_MAPS_API_KEY` alone. The **hook denies `flutter build apk` on Windows
only** for the same reason.

**The macOS trap is the JDK.** Flutter ignores `JAVA_HOME` and prefers the JDK
bundled with Android Studio, which is currently **25** — and Gradle 8.14, the
wrapper this repo pins, supports at most 24. The build then fails inside Gradle
with a message about Gradle that names nothing pointing at the JDK. It cost a
build here before it was recognised. `build_apk.sh` checks this before building
and refuses with the fix; to set it once:

```bash
flutter config --jdk-dir="$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home"
```

JDK 17 is deliberate — it matches `java-version: '17'` in `android.yml`, so a
local build and CI do not diverge. Flutter is likewise pinned to 3.41.9 to match
the workflow's `flutter-version: '3.41.x'`.

## Bump both version fields first

The script refuses to build when they disagree, which is the point — the drift
it replaces was invisible because nothing compared the two.

1. `version:` in `pubspec.yaml` — e.g. `0.50.1+231`
2. `appVersion` and `appBuildStamp` in `lib/core/util/app_build.dart`

`appVersion` must equal the pubspec version without the build number.
`appBuildStamp` is a dated phrase (`2026-08-19-no-receipt-storm`) shown on the
profile screen and in the boot log; it is how a tester says what they are
running without reading a number. A stamp that reads like the last one is the
single most common way someone ends up testing the wrong APK.

## Install over, never uninstall

Uninstalling wipes Hive and the Keystore: new identity, new Nostr key, every
existing chat on that device broken. A PreToolUse hook blocks `adb uninstall`.

"App not installed" almost always means the **signing fingerprint** changed,
not that the APK is bad. CI prints the signer and SHA-256 in the release notes
for exactly this comparison. CI caches its sideload key
(`cubechat-sideload-keystore-v2`); if that cache is evicted, the next build mints
a new key and that one install has to be replaced by hand.

Never let Gradle fall back to `~/.android/debug.keystore` — that signs as
`CN=Android Debug, O=Android, C=US`, which Play Protect blocks outright with
"never seen an app from this developer". That is not a signing failure and
cannot be fixed by signing harder.

## CI

`.github/workflows/android.yml` and `ios.yml`. Both gate on `verify` first:
analyze, then `flutter test --exclude-tags golden`. A build is not published
from a tree that fails its own tests.

- Analyze runs with `--no-fatal-infos --no-fatal-warnings` to get a zero exit,
  then greps the log for errors and warnings. The tree carries several hundred
  style infos (mostly missing trailing commas); making those block would mean
  the gate is switched off within a day. **The separator differs by platform:**
  `error -` locally on Windows, `error •` on the Linux runner — match both.
- Goldens are excluded because font rasterisation differs enough between Windows
  and Linux to fail them by ~3% of pixels every time.
- Android builds `--split-per-abi` then universal, and publishes to a rolling
  `apk-latest` prerelease. Testers take `cubechat-arm64.apk`: a third the size of
  universal, and every phone of the last decade is arm64. Deliberately **not**
  uploaded as a workflow artifact as well — that duplicate is what exhausted the
  account's 6.4 GB artifact quota and broke the iOS job.
- `GOOGLE_MAPS_API_KEY` is a repository secret and the Android job fails fast if
  it is empty. Without it the map draws nothing but the Google logo on release
  builds, and the iOS Map tab crashes.
- iOS builds an unsigned IPA on a macOS runner for Sideloadly/AltStore. A red iOS
  build right after an action bump is usually the macOS cache service
  (`ENOTFOUND`, exit 28) — re-run before reverting anything.

Sideloadly appends the Apple team id to the bundle id, so an iOS-restricted Maps
key must list the suffixed name. Read the `[BUILD]` boot line to see which
bundle id actually shipped.

## Branding assets

Regenerated only when the logo changes:

```bash
flutter run -t tool/export_logo.dart -d windows
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```
