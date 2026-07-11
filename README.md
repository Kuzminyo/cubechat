# cubechat

Encrypted peer-to-peer messaging over Bluetooth mesh.
Inspired by [bitchat](https://github.com/permissionlesstech/bitchat). Glassmorphism UI.

## Status

**v0.1 — working encrypted mesh.** BLE central + peripheral transport, Noise XX
sessions, forward-secret (X3DH) text, chunked image/voice transfer, multi-hop
relay with dedup + store-and-forward, and encrypted local storage all land. The
Nostr internet-fallback (M6) is in progress — its offline foundation is built
and unit-tested; the secp256k1 signer and live relay pool remain.

## Roadmap

- [x] M0 — Flutter scaffold, glass design system, EN/UK i18n, mock chat UI
- [x] M0.5 — Smooth animation pass (aurora drift, hero avatars, bubble entrance, sliding nav)
- [x] M1 — BLE central scanning (`flutter_blue_plus`), permissions, peer discovery UI
- [x] M1.5 — Native peripheral mode (Swift + Kotlin via MethodChannel)
- [x] M2 — Noise Protocol XX handshake + ChaCha20-Poly1305 transport
- [x] M3 — Multi-hop mesh relay + message dedup + store-and-forward outbox
- [x] M4 — Local message store (Hive), key storage (flutter_secure_storage)
- [x] M5 — Emergency wipe, IRC-style commands, image + voice transfer (signed manifests)
- [~] M6 — Nostr fallback transport (NIP-17) — foundation built (see below)

> The `[x]` marks above reflect what's implemented and covered by the 126-test
> suite (`flutter test`). LZ4 payload compression (originally scoped under M3)
> is not yet wired.

### Nostr fallback (M6, in progress)

Goal: when a recipient is out of BLE range, relay the *same encrypted cubechat
frame* through public Nostr relays over the internet, and pull frames the mesh
missed. Nostr is used as a dumb store-and-forward pipe — the frame is already
end-to-end encrypted (SealedBox / X3DH) and signed, so relays never see
plaintext.

Built and unit-tested (`lib/core/`, pure/offline):

- **`crypto/secp256k1.dart`** — a self-contained secp256k1 + BIP-340 Schnorr
  signer/verifier in pure Dart (no new dependency), pinned to the **official
  BIP-340 test vectors**. Nostr requires this curve; the app's `cryptography`
  stack (Ed25519 / X25519) doesn't provide it.
- **`transport/nostr/nostr_signer.dart`** — `Secp256k1NostrSigner`, which
  **deterministically derives** a stable Nostr key from the Ed25519 identity
  seed (`HKDF-SHA256(seed, info="cubechat/nostr-secp256k1/v1")`, reduced into
  `[1, n-1]`), so no extra key material is persisted. Tests verify the produced
  signatures with the BIP-340 verifier.
- **`transport/nostr/nostr_event.dart`** — NIP-01 event model with canonical
  serialization and SHA-256 event id.
- **`transport/nostr/nostr_frame_codec.dart`** — `cc1:` self-identifying
  `Frame`↔event-content codec so a shared public relay's unrelated traffic is
  cheaply skipped.
- **`transport/nostr/nostr_transport.dart`** — the `sendFrame` /
  `inboundFrames` seam `MessagingService` will call, over two abstractions:
  `NostrRelayClient` (WebSocket pool) and `NostrEventSigner`
  (`Secp256k1NostrSigner`). Tests drive the flow with an in-memory fake relay,
  proving a frame round-trips byte-for-byte.

Remaining (needs a device/network to verify, so not done here):

1. **Announcement field.** Advertise `npub` in the signed peer announcement
   (alongside the existing signed prekey) so peers learn each other's off-mesh
   address.
2. **Relay pool.** A real `NostrRelayClient` over `web_socket_channel` —
   REQ/EVENT/EOSE framing, a small relay pool, and reconnect. Must verify each
   inbound event's Schnorr signature (via `Secp256k1.verify`) before emitting.
3. **MessagingService wiring.** Push to Nostr when a BLE send yields
   `deliveredVia == 0`, and feed `inboundFrames()` into `_handleInboundBytes`
   so off-mesh frames flow through the same decrypt/deliver path.

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

Requires Flutter SDK ≥ 3.27. Platform folders for `android/`, `ios/`,
`windows/` and `web/` are checked in — just pull dependencies and run.

```bash
flutter pub get
flutter gen-l10n
flutter run
```

### Targets

| Target | Command | BLE works? | Notes |
|---|---|---|---|
| **Android device** | `flutter run -d <id>` | ✅ central + peripheral | full mesh demo, two phones see each other |
| **iOS device** | `flutter run -d <id>` | ✅ central + peripheral | requires Mac for build |
| **Web (Chrome)** | `flutter run -d chrome` | ❌ unsupported by browser | UI demo only, the Peers screen shows "Bluetooth LE not available" |
| **Windows desktop** | `flutter run -d windows` | ❌ central only | needs Visual Studio 2022 with C++ workload |

### Build static web bundle

```bash
flutter build web --release
# Output in build/web/ — drop on any static host (GitHub Pages, Netlify, S3)
```

### iOS build without a Mac (GitHub Actions + Sideloadly)

The repo ships `.github/workflows/ios.yml`, which runs Flutter on a
GitHub-hosted macOS runner and produces an unsigned `.ipa` you can
install with [Sideloadly](https://sideloadly.io/) or
[AltStore](https://altstore.io/) using a free Apple ID (7-day
re-sign cycle).

1. Push a commit to `main` (or run the workflow manually from the
   Actions tab via "Run workflow")
2. Wait ~10 minutes for the macOS runner to build
3. Open the finished run → Summary → Artifacts → download
   `cubechat-ios-unsigned-<sha>.zip`
4. Unzip → `cubechat-unsigned.ipa`
5. Open Sideloadly on Windows, plug iPhone via USB, drag the IPA in,
   sign with your free Apple ID
6. On iPhone: `Settings → General → VPN & Device Management` → trust
   the new profile

App expires after 7 days; rerun Sideloadly to refresh.

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
