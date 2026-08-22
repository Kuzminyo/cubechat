---
name: release-build
description: How to build, version and ship a cubechat APK or IPA on this machine. Load when the task involves building a release, producing an APK or IPA for a tester, bumping the version or build stamp, installing on a phone, an "App not installed" failure, a signing fingerprint, the GitHub Actions workflows, or the Google Maps key.
user-invocable: true
---

# Building and shipping cubechat

## `flutter build apk` does not work here, and the error lies

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
`pub cache repair`.

A PreToolUse hook blocks `flutter build apk` for this reason. Build with:

```bash
powershell -ExecutionPolicy Bypass -File tool/build_apk.ps1
```

The script runs pub get, repairs the file, pins `android/local.properties` to
the pubspec version, invokes Gradle directly (going through `flutter build`
would just rewrite the file broken again), and verifies the stamp landed inside
`libapp.so`.

Flags: `-Clean` runs `flutter clean` first — several minutes slower, for
failures that smell like stale intermediates. `-SkipPubGet` only when nothing
has touched pubspec since the last run.

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
