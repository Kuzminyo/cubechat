# cubechat

Encrypted peer-to-peer messaging over Bluetooth mesh.
Inspired by [bitchat](https://github.com/permissionlesstech/bitchat). Glassmorphism UI.

## Status

**v0.1 — UI scaffold.** Design system, navigation, and chat screens with mock data.
Bluetooth mesh transport and Noise Protocol encryption land in the next milestones.

## Roadmap

- [x] M0 — Flutter scaffold, glass design system, EN/UK i18n, mock chat UI
- [x] M0.5 — Smooth animation pass (aurora drift, hero avatars, bubble entrance, sliding nav)
- [x] M1 — BLE central scanning (`flutter_blue_plus`), permissions, peer discovery UI
- [x] M1.5 — Native peripheral mode (Swift + Kotlin via MethodChannel)
- [ ] M2 — Noise Protocol XX handshake + ChaCha20-Poly1305 transport
- [ ] M3 — Multi-hop mesh relay + message dedup + LZ4 compression
- [ ] M4 — Local message store (Hive), key storage (flutter_secure_storage)
- [ ] M5 — Emergency wipe, IRC-style commands, image transfer
- [ ] M6 — Nostr fallback transport (NIP-17)

### Peripheral mode (M1.5)

`flutter_blue_plus` is central-only. We added the peripheral side as a thin
`MethodChannel` bridge talking to native code:

- **Android**: `android/app/src/main/kotlin/com/cubechat/cubechat/CubechatBlePeripheralPlugin.kt`
  uses `BluetoothLeAdvertiser` + `BluetoothGattServer` to advertise the service
  UUID (in the primary packet) plus the device name (in scan response) and
  exposes the three characteristics. Registered in `MainActivity.kt`.
- **iOS**: `ios/Runner/CubechatBlePeripheralPlugin.swift` does the same with
  `CBPeripheralManager`. Registered in `AppDelegate.swift`.

The peripheral starts automatically when the user opens the Peers screen and
permissions / adapter are OK. Status surfaces as a "Broadcasting · N centrals
connected" chip in the screen header.

## Run (first time)

Requires Flutter SDK ≥ 3.27.

```bash
# 1. Generate android/ and ios/ platform folders (only once)
flutter create . --platforms=android,ios --org com.cubechat --project-name cubechat

# 2. Pull dependencies
flutter pub get

# 3. Generate localization (lib/l10n/app_localizations.dart)
flutter gen-l10n

# 4. Run on a connected device or emulator
flutter run
```

After that, day-to-day:

```bash
flutter run
```

### Branding

The logo is **drawn programmatically** by `CubeLogoPainter` so the in-app
brand mark scales perfectly at every size and stays automatic. For
launcher icons / splash (where the platform requires real PNG files),
generate them once with:

```bash
flutter run -t tool/export_logo.dart -d windows
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```

The exporter rasterizes the painter to `assets/logo/cube.png` (solid bg,
for iOS) and `assets/logo/cube_transparent.png` (transparent, for Android
adaptive foreground). Detail in `assets/logo/README.md`.

`flutter gen-l10n` re-runs automatically as part of `flutter pub get` thanks to `generate: true` in pubspec.

## Project layout

```
lib/
├── main.dart                  # entry point
├── app.dart                   # MaterialApp + router + theme
├── core/
│   ├── theme/                 # colors, typography, ThemeData
│   ├── widgets/               # reusable glass widgets
│   └── routing/               # go_router config
├── features/
│   ├── chats/                 # chats list
│   ├── chat/                  # single conversation
│   └── profile/               # settings + identity
└── l10n/                      # ARB files (en, uk)
```

## License

TBD.
