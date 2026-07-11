# cubechat

**Encrypted, anonymous, serverless messaging over a Bluetooth Low Energy mesh.**
No accounts, no phone numbers, no internet required. Inspired by
[bitchat](https://github.com/permissionlesstech/bitchat); built in Flutter with
a glassmorphism UI.

Two phones in Bluetooth range talk directly. Phones out of range are reached
over multi-hop relay through the phones in between. Everything is end-to-end
encrypted; the only identity is a cryptographic key you generate on first
launch.

---

## Status

Well past a UI scaffold: the BLE mesh, the Noise-encrypted transport, persistent
storage, group channels, media, and a full set of messaging features are all
implemented and covered by **186 passing tests** (including known-answer vectors
for the crypto). An optional internet-fallback transport (Nostr) has its
cryptographic core done and vector-verified; wiring it into the app is the
remaining work.

Runs on **Android** and **iOS** (real Bluetooth). Web/desktop build and run for
UI work but have no BLE.

---

## Features

**Messaging**
- 1:1 chats with delivery **and read receipts**
- Emoji **reactions** on any message
- **Edit** your own messages (inline, Telegram-style) and **delete** them —
  *for me* (local) or *for everyone* (retracted over the wire)
- **Images** and **voice messages** (chunked, with a signed manifest and SHA-256
  reassembly check; live waveform while recording)
- **Group channels** — shared-key rooms broadcast across the mesh (`/join #room`)
- **Channel invites** — hand a peer the channel key over their 1:1 encrypted link
- **Favorites**, unread badges, search, and system notifications (suppressed for
  the chat you're actively reading)

**Trust & privacy**
- **Out-of-band verification**: compare two fingerprints in person to confirm no
  man-in-the-middle; verified peers get a shield badge
- **Key-rotation warnings**: if a peer's signing key changes, the chat flags it
  and asks you to re-verify
- **Anonymous by default**: no device name is ever broadcast; unnamed peers show
  as `Anonymous <tag>` where the tag is derived from their public key
- **Emergency wipe**: triple-tap the logo to erase every key, peer, and message

**Transport**
- BLE **central + peripheral** — every phone both scans and advertises
- **Multi-hop mesh relay** with TTL and per-message deduplication
- **Store-and-forward**: messages for an offline peer are held (encrypted) and
  delivered automatically when they come back into range
- Automatic reconnect with address-rotation rescan and backoff

**Commands** (IRC-style, typed into any chat)
`/nick <name>` · `/who` · `/join #x [pw]` · `/leave` · `/channels` · `/clear` ·
`/wipe yes` · `/help`

---

## Security & cryptography

All primitives come from the vetted [`cryptography`](https://pub.dev/packages/cryptography)
package (X25519, ChaCha20-Poly1305, BLAKE2s, HKDF, Ed25519) and
[`pointycastle`](https://pub.dev/packages/pointycastle) (secp256k1). The
Noise/X3DH/NIP-44 framing is implemented in-repo and pinned to test vectors.

| Layer | Purpose | Primitive |
|---|---|---|
| **Noise Protocol XX** | Mutually-authenticated session over a direct BLE link | X25519 + ChaCha20-Poly1305 + BLAKE2s, spec-faithful (§5 SymmetricState, HMAC-BLAKE2s HKDF, correct 96-bit nonce) |
| **X3DH** | Per-message forward secrecy for multi-hop / async delivery | X25519 signed prekeys + ephemeral keys |
| **SealedBox** | Anonymous encryption to a peer we can't hold a session with (relays forward without decrypting) | libsodium-style `crypto_box_seal` |
| **SignedPayload** | Proves message authorship end-to-end | Ed25519 over a route-bound context (origin ‖ dest ‖ msgId ‖ timestamp) |
| **Channel crypto** | Shared-key group rooms | key = BLAKE2s(name ‖ password); ChaCha20-Poly1305; 8-byte public tag selects the room without trial decryption |
| **At rest** | Chat history, roster, keys | AES-encrypted Hive boxes; the AES key + identity private key live in the OS Keystore/Keychain (`flutter_secure_storage`) |

**Two-tier envelope.** Every application message is wrapped as: outer cipher
(SealedBox `0x01`, X3DH `0x02`, or channel `0x03`) → inner `SignedPayload`
(Ed25519) → typed inner payload. So relays route without decrypting, the
recipient decrypts, and the signature proves who sent it.

**Replay & dedup.** Signed timestamps + a 1-hour replay window; a dedup cache
keyed on `(originPubkeyHash, msgId)` drops loops and reflections across the mesh.

> **Scope note.** Group channels use one shared symmetric key (no per-sender
> forward secrecy — that needs a group key-agreement protocol like MLS, out of
> scope). Author authenticity within a channel still holds via the Ed25519
> signature. The Noise implementation is verified for self-consistency, not
> against the official Noise KATs (fine for cubechat↔cubechat).

### Nostr internet fallback (optional, M6)

The cryptographic core is implemented in `lib/core/nostr/` and **pinned to the
official [NIP-44 vectors](https://github.com/paulmillr/nip44)**:

- **NIP-44 v2** — conversation key (secp256k1 ECDH + HKDF), ChaCha20 + HMAC-SHA256,
  padding. Byte-exact against the reference `encrypt`/`decrypt`/`calc_padded_len`
  vectors.
- **NIP-17 gift wrap** — rumor (kind 14) → seal (kind 13) → gift wrap (kind 1059),
  each NIP-44-encrypted, with BIP340 Schnorr event signatures and an
  impersonation guard (the rumor's claimed author must equal the seal signer).
- **Relay client** — NIP-01 `EVENT`/`REQ`/`OK`/`EOSE` over WebSocket.

Not yet wired into the app: a Nostr identity + a way to map BLE peers to their
Nostr pubkeys, the inbound/outbound bridge to the message store, and relay
config UI.

---

## Wire protocol

Every BLE write/notification carries one **frame**: `[type:1][payload:N]`.

```
Frame
 ├─ noiseHandshake1/2/3   raw Noise XX messages
 ├─ peerAnnouncement       signed (pubkey, nickname, signed prekey) broadcast
 ├─ reset                  drop-your-session
 └─ transport              TransportEnvelope:
        [originHash:8][destHash:8][msgId:16][ttl:1][body]
        body = [cipherTag:1][ciphertext]
               ciphertext → SignedPayload → InnerPayload:
                 text · imageChunk · audioChunk · mediaManifest ·
                 receipt · reaction · channelInvite · edit · delete
```

`destHash` all-zero = broadcast (announcements, channels). `ttl` starts at 7 and
each relay decrements it. Short text is padded to a 48-byte bucket to hide
length from passive sniffers.

---

## Architecture

Flutter + Riverpod (Notifier pattern), `go_router` with a `StatefulShellRoute`
so tabs keep their state. The floating glass nav bar and chat-input capsule are
overlays, not welded plates; the animated aurora backdrop is a single
`CustomPainter` so it never rebuilds the widget tree.

```
lib/
├── main.dart · app.dart               # entry, MaterialApp.router, lifecycle
├── core/
│   ├── crypto/       # Noise (XX), X3DH, SealedBox, SignedPayload, prekeys,
│   │                 #   channel crypto, identity
│   ├── nostr/        # secp256k1, NIP-44, NIP-17, event signing, relay client
│   ├── transport/    # messaging service, envelope, frame, dedup, store-forward,
│   │                 #   chat sessions, inner payloads
│   ├── ble/          # scanner, peripheral bridge, permissions, constants
│   ├── storage/      # encrypted Hive boxes + AES cipher provider
│   ├── identity/     # nickname, anon naming, emergency wipe
│   ├── notifications/· locale/ · routing/ · theme/ · widgets/ · util(s)/
├── features/
│   ├── chats/        # chat list, favorites, tiles, actions
│   ├── chat/         # conversation screen, bubbles, input, voice, edit target
│   ├── channels/     # channel model + controller
│   ├── peers/        # Nearby discovery, peripheral controller, verification
│   └── profile/      # settings, identity, diagnostics
└── l10n/             # ARB files (en, uk)
```

### Peripheral mode

`flutter_blue_plus` is central-only, so the peripheral side is a thin
`MethodChannel` bridge to native code:

- **Android** — `CubechatBlePeripheralPlugin.kt` uses `BluetoothLeAdvertiser` +
  `BluetoothGattServer` (service UUID in the primary packet, name in scan
  response). Registered in `MainActivity.kt`.
- **iOS** — `CubechatBlePeripheralPlugin.swift` does the same with
  `CBPeripheralManager`, registered in `AppDelegate.swift`.

It starts automatically when the Peers screen opens (permissions/adapter
permitting) and surfaces as a "Broadcasting · N centrals connected" chip.

---

## Build & run

Requires **Flutter SDK ≥ 3.27**. Platform folders (`android/`, `ios/`,
`windows/`, `web/`) are checked in.

```bash
flutter pub get      # also runs gen-l10n (generate: true in pubspec)
flutter test         # 186 tests, incl. crypto known-answer vectors
flutter run          # pick a target below
```

| Target | Command | BLE | Notes |
|---|---|---|---|
| **Android device** | `flutter run -d <id>` | ✅ central + peripheral | full mesh — two phones see each other |
| **iOS device** | `flutter run -d <id>` | ✅ central + peripheral | needs a Mac to build |
| **Web (Chrome)** | `flutter run -d chrome` | ❌ | UI only; Peers shows "Bluetooth LE not available" |
| **Windows desktop** | `flutter run -d windows` | ❌ | needs Visual Studio 2022 + "Desktop development with C++" |

```bash
flutter build apk --release   # → build/app/outputs/flutter-apk/app-release.apk
flutter build web --release   # → build/web/ (any static host)
```

> If `flutter` isn't on your PATH, call it by full path
> (e.g. `& "C:\Users\you\flutter\bin\flutter.bat" run`) or add `…\flutter\bin`
> to PATH. Building for Android on Windows needs symlink support — enable
> Developer Mode (`start ms-settings:developers`).

### iOS without a Mac (GitHub Actions + Sideloadly)

`.github/workflows/ios.yml` builds an unsigned `.ipa` on a GitHub-hosted macOS
runner. Push to `main` (or run the workflow manually) → download the
`cubechat-ios-unsigned-<sha>` artifact → sideload with
[Sideloadly](https://sideloadly.io/)/[AltStore](https://altstore.io/) and a free
Apple ID (7-day re-sign cycle) → trust the profile under
`Settings → General → VPN & Device Management`.

### Branding

The in-app logo is drawn programmatically by `CubeLogoPainter` so it scales at
any size. Launcher/splash PNGs are generated once:

```bash
flutter run -t tool/export_logo.dart -d windows   # rasterizes the painter
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```

---

## Testing

`flutter test` — **186 tests** across 22 files. Highlights:

- `noise_xx_test`, `x3dh_test`, `sealed_box_test`, `signed_payload_test`,
  `fs_message_test`, `announcement_test` — session + message crypto
- `nip44_test`, `nip17_test` — Nostr crypto pinned to the **official NIP-44
  vectors** + gift-wrap round-trip and impersonation guards
- `nostr_relay_test` — relay client against an in-process WebSocket server
- `channel_crypto_test`, `channel_invite_test`, `receipt_reaction_test`,
  `edit_delete_test` — feature wire formats
- `dedup_cache_test`, `store_forward_cache_test`, `hive_cipher_test` — mesh +
  storage (incl. the storage-key single-flight race)
- widget tests for the chat/nav UI

---

## Roadmap

- [x] **M0** — Flutter scaffold, glass design system, EN/UK i18n
- [x] **M0.5** — Animation pass (aurora, hero avatars, bubble entrance, nav)
- [x] **M1** — BLE central scanning, permissions, peer discovery
- [x] **M1.5** — Native peripheral mode (Swift + Kotlin via MethodChannel)
- [x] **M2** — Noise XX handshake + ChaCha20-Poly1305 transport
- [x] **M3** — Multi-hop mesh relay + message dedup + store-and-forward
      *(LZ4 compression intentionally dropped — it defeats the length-hiding
      padding and is a CRIME/BREACH-class leak with encryption)*
- [x] **M4** — Encrypted Hive store + Keystore/Keychain key storage
- [x] **M5** — Emergency wipe, IRC commands, image + voice transfer
- [x] **M5.5** — Channels, receipts, reactions, edit/delete, favorites, floating
      Telegram-style UI, anonymous naming
- [~] **M6** — Nostr fallback: **crypto core (NIP-44 v2 + NIP-17) + relay client
      done and vector-verified**; identity bridging, message-store integration,
      and relay UI remain

---

## License

TBD.
