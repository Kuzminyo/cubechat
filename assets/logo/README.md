# Logo asset

Drop the brand logo here as `cube.png`.

## Requirements

- **Filename:** `cube.png` (lowercase)
- **Format:** PNG with **transparent background** (the cube only — no white box around it)
- **Size:** at least 1024×1024 px (the launcher-icon generator downsamples for every density)
- **Aspect:** square; the cube centered with ~5% margin on each side

## What gets generated from it

| Output | Tool | Trigger |
|---|---|---|
| Android launcher icons (mipmap-* + adaptive) | `flutter_launcher_icons` | `dart run flutter_launcher_icons` |
| iOS app icons (Assets.xcassets) | `flutter_launcher_icons` | same |
| Android 12 / iOS splash screen | `flutter_native_splash` | `dart run flutter_native_splash:create` |
| In-app `CubeLogo` widget (chats / peers / profile headers) | `Image.asset` direct | nothing — picked up at runtime |

## Setup commands after placing the file

```powershell
cd Y:\projects\cubechat
flutter pub get
dart run flutter_launcher_icons
dart run flutter_native_splash:create
flutter run
```

## Transparency note

If the source PNG has a white background, the in-app logo will show a white
square against the dark aurora theme — looks broken. Strip the background
first (any image editor, or `https://www.remove.bg/` for a one-shot).

For iOS launcher icons specifically App Store rejects transparent PNGs;
`remove_alpha_ios: true` in `pubspec.yaml` handles that automatically by
compositing onto the dark brand background.
