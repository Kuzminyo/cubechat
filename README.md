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
- [ ] M1.5 — Native peripheral mode (Swift + Kotlin via MethodChannel)
- [ ] M2 — Noise Protocol XX handshake + ChaCha20-Poly1305 transport
- [ ] M3 — Multi-hop mesh relay + message dedup + LZ4 compression
- [ ] M4 — Local message store (Hive), key storage (flutter_secure_storage)
- [ ] M5 — Emergency wipe, IRC-style commands, image transfer
- [ ] M6 — Nostr fallback transport (NIP-17)

### Why M1.5 exists

`flutter_blue_plus` is central-only — it can scan and connect to other devices
acting as peripherals, but cannot advertise its own GATT server. For a real
mesh every node must do *both*. The peripheral side lives in `lib/core/ble/
ble_peripheral.dart` as a `MethodChannel` interface; the Swift and Kotlin
implementations land in M1.5.

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
