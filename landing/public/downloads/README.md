# Download artifacts

Files served by the **Download** section. The Download buttons link here with
an HTML `download` attribute, so a click saves the file instead of navigating.

| Button  | File                          | Notes |
|---------|-------------------------------|-------|
| Android | `cubechat-0.1.0.apk`          | Real release build. **Git-ignored** (56 MB) — regenerate, see below. |
| iOS     | `cubechat-ios-sideload.txt`   | Sideload guide (no signed .ipa is distributable). |
| Source  | `cubechat-0.1.0-source.zip`   | Source snapshot (lib/test/tool/assets + manifests). |

## Regenerate

```bash
# Android APK (from repo root)
flutter build apk --release
cp build/app/outputs/flutter-apk/app-release.apk landing/public/downloads/cubechat-0.1.0.apk

# Source zip (PowerShell, from repo root)
Compress-Archive -Path lib,test,tool,assets,pubspec.yaml,pubspec.lock,README.md,analysis_options.yaml,l10n.yaml,devtools_options.yaml `
  -DestinationPath landing/public/downloads/cubechat-0.1.0-source.zip -Force
```

Bump the version in the filenames **and** in `src/components/Download.tsx`
(`ANDROID` / `SOURCE` constants) together.
