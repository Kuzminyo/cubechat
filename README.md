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

Feature-complete against the roadmap: the BLE mesh, the Noise-encrypted
transport, persistent storage, group channels, media, the full messaging
feature set, and the optional Nostr internet fallback are all implemented and
covered by **269 passing tests** (`flutter test`, including known-answer
vectors for the crypto).

Runs on **Android** and **iOS** (real Bluetooth). Web/desktop build and run for
UI work but have no BLE.

- [x] M0 — Flutter scaffold, glass design system, EN/UK i18n, mock chat UI
- [x] M0.5 — Smooth animation pass (aurora drift, hero avatars, bubble entrance, sliding nav)
- [x] M1 — BLE central scanning (`flutter_blue_plus`), permissions, peer discovery UI
- [x] M1.5 — Native peripheral mode (Swift + Kotlin via MethodChannel)
- [x] M2 — Noise Protocol XX handshake + ChaCha20-Poly1305 transport
- [x] M3 — Multi-hop mesh relay + message dedup + store-and-forward outbox
- [x] M4 — Local message store (Hive), key storage (flutter_secure_storage)
- [x] M5 — Emergency wipe, IRC-style commands, image + voice transfer (signed manifests)
- [x] M5.5 — Group channels, receipts/reactions, message edit/delete, reply/quote, block/mute peers
- [x] M6 — Nostr internet fallback (see below)

> The `[x]` marks above reflect what's implemented and covered by the 269-test
> suite (`flutter test`). LZ4 payload compression (originally scoped under M3)
> is intentionally dropped — it defeats the length-hiding padding.
>
> The one thing the test suite can't prove is real radio behaviour: two-phone
> BLE range/reconnect and a live public relay both need hardware.

---

## Features

**Messaging**
- 1:1 chats with delivery **and read receipts**
- Emoji **reactions** on any message
- **Replies** — long-press to quote a message; the quote rides in the envelope
- **Edit** your own messages (inline, Telegram-style) and **delete** them —
  *for me* (local) or *for everyone* (retracted over the wire)
- **Images** and **voice messages** (chunked, with a signed manifest and SHA-256
  reassembly check; live waveform while recording)
- **In-app gallery** — a custom multi-select photo picker (send several at once)
  and a Telegram-style swipeable full-screen viewer with pinch-zoom, save and
  share
- **Group channels** — shared-key rooms broadcast across the mesh (`/join #room`)
- **Channel invites** — hand a peer the channel key over their 1:1 encrypted link
- **Favorites**, real unread tracking (badge + highlighted tile that clears when
  you open the chat), search, and rich **MessagingStyle notifications** with the
  sender's avatar and an inline **Reply** box (suppressed for the chat you're
  actively reading)

**Trust & privacy**
- **Out-of-band verification**: compare two fingerprints in person to confirm no
  man-in-the-middle; verified peers get a shield badge
- **Key-rotation warnings**: if a peer's signing key changes, the chat flags it
  and asks you to re-verify
- **Anonymous by default**: no device name is ever broadcast; unnamed peers show
  as `Anonymous <tag>` where the tag is derived from their public key
- **Block / mute** a peer — blocked peers' messages are dropped on arrival,
  muted peers arrive silently
- **Emergency wipe**: triple-tap the logo to erase every key, peer, and message

**Transport**
- BLE **central + peripheral** — every phone both scans and advertises
- **Multi-hop mesh relay** with TTL and per-message deduplication
- **Store-and-forward**: messages for an offline peer are held (encrypted) and
  delivered automatically when they come back into range
- **Internet fallback (optional, off by default)** — when the mesh can't reach a
  peer, the same sealed frame goes out over public Nostr relays
- Automatic reconnect with address-rotation rescan and backoff

**Commands** (IRC-style, typed into any chat)
`/nick <name>` · `/who` · `/join #x [pw]` · `/leave` · `/channels` · `/clear` ·
`/wipe yes` · `/help`

---

## Security & cryptography

All primitives come from the vetted [`cryptography`](https://pub.dev/packages/cryptography)
package (X25519, ChaCha20-Poly1305, BLAKE2s, HKDF, Ed25519). secp256k1 +
BIP-340 Schnorr (for the Nostr fallback signer) is a self-contained pure-Dart
implementation in `lib/core/crypto/secp256k1.dart` — no extra dependency. The
Noise/X3DH/Nostr-event framing is implemented in-repo and pinned to test vectors.

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

When the mesh can't reach a peer, cubechat can push the **same encrypted frame**
through public Nostr relays instead of only holding it in the store-and-forward
buffer. Nostr is a dumb pipe: the frame is already sealed (SealedBox / X3DH) and
signed, so a relay carries ciphertext it cannot read. Lives in
`lib/core/transport/nostr/`.

- **`Secp256k1NostrSigner`** — deterministically derives a stable Nostr key
  from the Ed25519 identity seed (`HKDF-SHA256`, reduced into `[1, n-1]`), so
  no extra key material is persisted; signs NIP-01 events with BIP-340 Schnorr
  (pure-Dart, **pinned to the official BIP-340 vectors**).
- **NIP-01 event model + relay protocol** — canonical event serialization,
  SHA-256 event id, and the client↔relay `REQ`/`EVENT`/`CLOSE`/`OK`/`EOSE`
  framing, including `verifyInboundEvent` (the untrusted-relay gate that
  recomputes the event id and checks the Schnorr signature before anything
  reaches the app).
- **`cc1:` frame codec** — wraps the same encrypted cubechat `Frame` used on BLE
  inside a Nostr event, self-identifying so a shared relay's unrelated traffic
  is cheaply skipped.
- **`WebSocketNostrRelayClient`** — the relay pool: publishes to every connected
  relay, merges inbound events into one stream, de-duplicates by event id across
  relays, and reconnects with exponential backoff (replaying `since` so nothing
  is missed or re-downloaded).
- **Signed announcement carries the address** — the peer announcement (v0x04)
  signs each peer's `npub` alongside the signed prekey, so a relay can't swap in
  its own Nostr address.
- **`MessagingService` bridge** — a text or control frame the mesh couldn't
  deliver is published to the recipient's `npub`; if no relay accepts it, it
  still falls through to store-and-forward. Inbound relay frames re-enter the
  *same* dispatch as a BLE notification, so they get the same dedup, replay
  window, and signature checks.

**Off by default, and it should be.** A relay never sees plaintext, but it does
learn which two Nostr keys exchanged a message and when — metadata the BLE mesh
never leaks. So it is opt-in per device (Profile → Internet fallback), the relay
list is user-editable, and Emergency Wipe switches it back off.

---

## Wire protocol

Every BLE write/notification carries one **frame**: `[type:1][payload:N]`.

```
Frame
 ├─ noiseHandshake1/2/3   raw Noise XX messages
 ├─ peerAnnouncement       signed (pubkey, nickname, signed prekey) broadcast
 ├─ fragment               [fragId:4][index:1][count:1][slice] — link-layer split
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

**MTU-aware framing.** Real iOS↔Android links often negotiate an ATT MTU well
below the ~247 the code once assumed, and a frame larger than the link's usable
payload is silently truncated on the wire (the AEAD open then fails). Media
chunks are sized from the link's actual `negotiatedMtu` (`mtu_budget.dart`), and
any frame that still doesn't fit is split into `fragment` frames and rejoined by
the receiver *before* dispatch (`frame_fragment.dart`) — transparent to dedup,
replay and relay. The native peripheral side (Swift/Kotlin) queues notifies and
drains them on the BLE "ready to send" callback, so a media burst no longer
overruns the transmit queue and aborts the transfer.

---

## Architecture

Flutter + Riverpod (Notifier pattern), `go_router` with a `StatefulShellRoute`
so tabs keep their state. The floating glass nav bar and chat-input capsule are
overlays, not welded plates; the animated aurora backdrop is a single
`CustomPainter` so it never rebuilds the widget tree, and its drift runs off a
~30 fps wall-clock ticker (paused while backgrounded) rather than every vsync —
the blobs rebuild four shaders per paint, so at 120 fps on ProMotion it ran the
GPU hot even while the app sat idle.

```
lib/
├── main.dart · app.dart               # entry, MaterialApp.router, lifecycle
├── core/
│   ├── crypto/       # Noise (XX), X3DH, SealedBox, SignedPayload, prekeys,
│   │                 #   channel crypto, identity
│   ├── transport/    # messaging service, envelope, frame, dedup, store-forward,
│   │                 #   chat sessions, inner payloads, nostr/ (M6 signer, frame
│   │                 #   codec, relay protocol + WebSocket relay pool)
│   ├── ble/          # scanner, peripheral bridge, permissions, constants
│   ├── storage/      # encrypted Hive boxes + AES cipher provider
│   ├── identity/     # nickname, anon naming, emergency wipe
│   ├── notifications/· locale/ · routing/ · theme/ · widgets/ · util(s)/
├── features/
│   ├── chats/        # chat list, favorites, tiles, actions
│   ├── chat/         # conversation screen, bubbles, input, voice, edit target
│   ├── channels/     # channel model + controller
│   ├── peers/        # Nearby discovery, peripheral controller, verification
│   └── profile/      # settings, identity, diagnostics, relay settings
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

### Background delivery on aggressive OEMs (Xiaomi/MIUI, etc.)

BLE delivery while the app is backgrounded needs the OS to keep the process
alive. Most phones are fine once **Background mode** is on (Profile → Background)
and the battery-optimisation exemption is granted (the "Battery exempt" button
there). MIUI/HyperOS (Xiaomi/Redmi/POCO) additionally kill apps unless
**Autostart** is enabled for cubechat — grant it in *Settings → Apps → cubechat →
Autostart* (or Security app → Autostart), and set battery saver to *No
restrictions*. Without those, messages sent while cubechat is closed only arrive
after the peer reopens it.

---

## Build & run

Requires **Flutter SDK ≥ 3.27**. Platform folders (`android/`, `ios/`,
`windows/`, `web/`) are checked in.

```bash
flutter pub get      # also runs gen-l10n (generate: true in pubspec)
flutter test         # 269 tests, incl. crypto known-answer vectors
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

`flutter test` — **269 tests** across 32 files. Highlights:

- `noise_xx_test`, `x3dh_test`, `sealed_box_test`, `signed_payload_test`,
  `fs_message_test`, `announcement_test` — session + message crypto
- `secp256k1_bip340_test` — pure-Dart secp256k1 signer pinned to the
  **official BIP-340 vectors**
- `nostr_signer_test`, `nostr_event_test`, `nostr_relay_protocol_test`,
  `nostr_transport_test` — Nostr fallback signer, event framing, relay
  protocol, and the in-memory fake-relay round-trip
- `websocket_relay_client_test` — the relay pool driven against a **real
  in-process WebSocket relay**: publish, REQ filter, cross-relay dedup,
  forged-signature rejection, and the no-relay throw that keeps
  store-and-forward as the backstop
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
- [x] **M5.5** — Channels, receipts, reactions, edit/delete, reply/quote,
      block/mute, favorites, floating Telegram-style UI, anonymous naming
- [x] **M6** — Nostr internet fallback: secp256k1 signer, event framing, relay
      protocol, WebSocket relay pool, `MessagingService` bridge, and the relay
      settings screen — opt-in, off by default

---

## License

[MIT](LICENSE) © 2026 Kuzminyo
