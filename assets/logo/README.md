# Logo assets

The cubechat brand mark is **drawn programmatically** by
`CubeLogoPainter` (in `lib/core/widgets/cube_logo.dart`). For in-app use
no asset file is required — the painter scales crisply at every size and
stays in sync with the brand palette automatically.

This directory exists for the **rasterized variants** that the platform
needs as actual PNG files (launcher icons, splash screen). They are
generated, not hand-edited.

## Generated files

| File | Purpose | Background |
|---|---|---|
| `cube.png` | iOS launcher icon, splash foreground | solid `#06140D` |
| `cube_transparent.png` | Android adaptive icon foreground | transparent |

## How to regenerate

```bash
cd Y:\projects\cubechat
flutter pub get
flutter run -t tool/export_logo.dart -d windows
```

(On macOS use `-d macos`, on Linux `-d linux`. The window opens for ~1s
showing the cube and the status line, writes both PNGs, then exits.)

After that, rebuild the platform icons + splash from the freshly-generated
PNGs:

```bash
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```

## Want a different design?

Edit `CubeLogoPainter` in `lib/core/widgets/cube_logo.dart` — the colours,
face geometry, edge highlights, shadow, and glow all live there. Re-run
the exporter and the icon pipeline to propagate the change.
