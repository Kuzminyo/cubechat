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
covered by **449 passing tests** (`flutter test`, including known-answer
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
- [x] M6.5 — Contact cards: open a chat with someone who has never been in BLE range
- [x] M7 — Rotating peer IDs + sealed announcements (Profile → Discoverable nearby)
- [x] M7.5 — Noise IK: a stranger who dials you no longer learns your static key

> The `[x]` marks above reflect what's implemented and covered by the 449-test
> suite (`flutter test`). LZ4 payload compression (originally scoped under M3)
> is intentionally dropped — it defeats the length-hiding padding.
>
> The one thing the test suite can't prove is real radio behaviour: two-phone
> BLE range/reconnect and a live public relay both need hardware.

---

## Features

**Messaging**
- 1:1 chats with delivery **and read receipts**
- Emoji **reactions** on any message — long-press for the picker, or
  **double-tap** for a heart when that's all you meant
- **Replies** — **swipe a message left** (or long-press → Reply) to quote it;
  the quote rides in the envelope
- **Edit** your own messages (inline, Telegram-style) and **delete** them —
  *for me* (local) or *for everyone* (retracted over the wire)
- **Voice messages** — hold to talk and release to send, or slide up to lock
  hands-free; a locked recording gets a **trim editor** first (drag either end
  of the waveform, preview the selection, then send). The cut is a native
  re-mux, so it is lossless and best-effort: if a device can't do it, the
  untrimmed recording is sent rather than nothing
- **Images** and voice (chunked, with a signed manifest and SHA-256
  reassembly check; live waveform while recording). Hold the mic to talk,
  **slide up to lock** it hands-free, **slide left to discard**
- **In-app gallery** — a custom multi-select photo picker (send several at once)
  and a Telegram-style swipeable full-screen viewer with pinch-zoom, save and
  share
- **Group channels** — shared-key rooms broadcast across the mesh *and* over the
  relays, so a room works between people who are nowhere near each other
  (`/join #room`)
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
- **Multi-hop mesh relay** with a density-scaled TTL (full depth in a chain, cut
  in a crowd where flooding costs most) and per-message deduplication
- **Store-and-forward**: messages for an offline peer are held (encrypted) and
  delivered automatically when they come back into range
- **Internet fallback (optional, off by default)** — when the mesh can't reach a
  peer, the same sealed frame goes out over public Nostr relays
- **Contact cards** — start a chat with someone who has *never* been in
  Bluetooth range: share a signed identity card as text through any other app,
  they paste it, and messages flow over the relay from the first tap
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
| **Noise Protocol XX** | Meeting a stranger over a direct BLE link | X25519 + ChaCha20-Poly1305 + BLAKE2s, spec-faithful (§5 SymmetricState, HMAC-BLAKE2s HKDF, correct 96-bit nonce) |
| **Noise Protocol IK** | Calling a peer whose key we already hold — the responder never transmits its own | Same primitives; two messages, with the responder static as a pre-message |
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

### Rotating peer IDs, and the announcement that has to change with them

The 8-byte id on every frame used to be `BLAKE2s(x25519_pubkey)[0:8]`, computed
once and never again. Anyone recording the air could group a device's entire
history by those eight bytes without breaking a cipher — across BLE address
rotations that exist precisely to stop that. It is now

```
id(pubkey, epoch) = BLAKE2s("cubechat/peer-id/v1" ‖ pubkey ‖ epoch_be64)[0:8]
epoch             = unix_millis ~/ 1h
```

Still deterministic, so anyone holding the peer's public key recomputes it with
no negotiation and no state — which is what lets a recipient recognise its own
mail. But it is only stable for an hour. Receivers accept the previous, current
and next epoch (`PeerId.activeEpochs`): a frame held in store-and-forward, or
sat in a relay backlog, arrives bearing the epoch it was minted in, and phones
are not NTP-synced. The store-and-forward buffer drains *all* of a peer's live
ids for the same reason — draining only the current one would strand exactly the
mail that waited longest. The pre-rotation fixed hash is still accepted on
receive so a staggered rollout survives; nothing mints it any more.

**Rotation alone would have been theatre.** The ids derive from the static
public key, and the mesh announcement broadcasts that key in the clear, with a
full hop budget, to everyone in range and beyond. One overheard announcement and
a listener recomputes every future id forever. So rotation ships with its
counterpart: **Profile → Discoverable nearby**.

| | Discoverable (default) | Off |
|---|---|---|
| Announcement | cleartext broadcast, relayed mesh-wide | sealed per contact, addressed to their rotating id |
| Handshake accepted | XX and IK | **IK only** |
| A stranger in range | learns your key, name, prekey, npub | sees opaque frames to meaningless ids, and gets no answer at all |
| Meeting someone new | walk up to them | they need a contact card |

Default on, because meeting someone by standing next to them is the premise of
the app and silently disabling it would break the Peers screen for a property
most people did not ask for.

### Two handshake patterns, and why

XX puts the responder's static key in its second message. Encrypted, so a
listener cannot read it — but the *initiator* can, and the initiator is whoever
just dialled you. So one deliberate connection hands a stranger the long-term
key that identifies the device forever and from which every rotating id is
derived, undoing both of the measures above.

**IK** (`Noise_IK_25519_ChaChaPoly_BLAKE2s`, `noise_ik_handshake_state.dart`)
never transmits it:

```
  <- s                     pre-message: the initiator already has it
  -> e, es, s, ss
  <- e, ee, se
```

The opener is encrypted under `es` — a DH against the responder's static key —
so producing one that decrypts *is* proof of already holding it. Someone
without it gets no session, no key, and no reply. It is also a round trip
shorter, and the initiator's own key travels encrypted rather than in the clear.

The two are used together: IK whenever we already know who we are calling
(a chat opened from the Chats list, a reconnect within the same run), XX
otherwise. With discovery **off** the responder refuses XX outright, which is
what closes the hole.

> **How a contact finds you.** BLE advertises a service UUID and a rotating
> hardware address — not an identity — so an IK opener had nobody to be
> addressed at. The advertisement now carries the **rotating peer id**: eight
> bytes a contact resolves through the index they already build, and that mean
> nothing to anyone else. Android puts it in service data (a local name there
> would mean renaming the Bluetooth adapter system-wide); iOS puts it in the
> local name, because CoreBluetooth cannot advertise service data at all. It is
> re-advertised when the epoch turns, since a contact computes the current one.
>
> This replaced broadcasting the **nickname**, which was a permanent handle any
> passive scanner could follow forever — and on Android it replaced
> `setIncludeDeviceName(true)`, which was putting the phone's own Bluetooth
> name ("Galaxy S24") on the air, flatly contradicting the anonymity the rest
> of the app is built around.
>
> One standard IK caveat also applies: an attacker who later compromises the
> responder's static key can decrypt a recorded first message and learn *who*
> was calling. Message contents stay safe — transport keys come from the
> ephemerals — and the application layer adds its own forward secrecy on top.

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

### Contact cards — starting a chat with no BLE at all

The fallback above assumes you already know the peer, and until now the only way
to learn someone was to stand next to them: the signed announcement that carries
their keys travelled over Bluetooth and nowhere else. Two people in different
cities therefore couldn't open a chat at all — the relay could have carried the
message, but neither side held the keys to encrypt one.

A **contact card** is that missing handshake, moved off the radio. It is the
*same* signed `PeerAnnouncement` the mesh broadcasts, base64'd into a string you
can send through any other app:

```
cubechat:c1:<base64url(signed announcement)>
```

Because it's the announcement verbatim, there is no second wire format and no
new signing context — importing a card runs the identical
`PeerAnnouncement.verifyAndDecode` gate a mesh announcement does, so a card
edited in transit fails the Ed25519 check before it can reach the roster
(`lib/core/transport/contact_card.dart`). The parser is deliberately forgiving
about *packaging* — surrounding chat text, injected line breaks, a stripped
scheme — and unforgiving about content.

**The reply path.** A card only travels one way: they now hold your keys, but
you hold none of theirs, and an inbound frame carries just an 8-byte origin hash
that cannot be reversed into an identity. So the first thing sent to a peer's
`npub` is our own signed announcement (`_announceOverNostrTo`, once per process
per peer). Without it our message would land in their app attributable to no
chat, and they'd have no address to answer at.

That introduction is **sealed to the recipient**, unlike its mesh counterpart.
On BLE an announcement has to be cleartext — it's addressed to whoever is in
range. A public relay is a different room: events there are readable by anyone
who asks, so publishing the bundle as-is would park a *human-readable nickname*
next to a Nostr pubkey, permanently, for any passive scraper — the one thing
every other frame on this path is careful not to leak. So it goes out as
`[0x01][SealedBox to their X25519 key]` (we have that key — it's what a card is
for), and the tag can't be mistaken for a plaintext announcement, which always
opens with version `0x04`. It also carries `ttl: 1`: a point-to-point
introduction, not a broadcast, so the receiver decrementing it to zero stops it
being flooded across their local Bluetooth neighbourhood, where nobody could
open it anyway.

> **A card proves consistency, not provenance.** The signature says the bundle
> is internally coherent and unmodified; it says nothing about *who handed it to
> you*. Anyone can mint a card for their own keys under any nickname, and a card
> forwarded through a chat app could have been swapped in transit. So a peer
> added this way starts **unverified** — compare fingerprints in person or over
> a call (Peers → verification) before trusting the identity. Accepting an
> introduction over a relay is likewise trust-on-first-use: it is what lets a
> stranger who knows your `npub` appear in your roster, the same exposure as
> being messageable at all.

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

`destHash` all-zero = broadcast (announcements, channels). Each relay decrements
`ttl`. Short text is padded to a 48-byte bucket to hide length from passive
sniffers.

**Hop budget scales with density.** A flood costs roughly `fanout ^ hops`, so
the two can't be set independently. With ≤5 links the mesh is a chain and the
full depth of **7** is what makes a distant node reachable at all; at **6+
links** the topology is a cluster, where every extra hop multiplies the copies
in flight while adding almost no reach — so the budget drops to **5**
(`TransportEnvelope.ttlForLinkCount`). The ceiling is applied both when minting
a frame *and* at every forward, using the density of whichever node is relaying:
a frame minted in a sparse corner carries the full budget, and spending all of
it once it reaches a crowd is exactly what turns a message into a storm. It only
ever lowers a ttl, so a deliberately short budget (a relay introduction rides at
1) is never inflated. The trade is real: a node deep in a crowd no longer reaches
a peer more than five hops out — rare in the topology that triggers the cut, and
store-and-forward plus the internet fallback remain as backstops.

**Media chunks are sized for the fragmenter, not for one write.** Matching a
chunk to the link's MTU is the obvious thing and it was badly wrong: every chunk
pays ~124 bytes of envelope, AEAD and chunk header no matter how little it
carries, so on a real 225-byte link a chunk held 101 bytes of photo and 124 of
packaging. A field log caught the result — **1367 chunks for one photo**, over
half the airtime spent on overhead, about two minutes on the radio. Since
fragmentation already splits oversized frames and rejoins them before dispatch,
a chunk no longer has to fit one write: at 4 KiB the same photo is ~34 chunks,
overhead drops under 3%, and both the bytes on air and the number of writes
roughly halve. `bleMediaChunkData` steps the target down on narrow links so the
frame can never need more fragments than the 255 the header can count.

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
overlays, not welded plates — and so is the chat header: it has no `AppBar` at
all. Header capsule, pinned island and composer are three siblings of the
message list inside one `Stack`, each carrying the same glass, with the list
padding itself top and bottom to clear them. That padding is *measured* rather
than guessed, because both ends change height (the composer grows with
multi-line text and the reply island, the header gains and loses the pinned
bar). The effect is that the conversation runs edge to edge behind them instead
of starting below a bar, and nothing ever shows a band of empty backdrop between
the islands and the chat. It also fixed a real bug for free: the pinned island
appearing used to re-parent the list, detaching the scroll position and snapping
the conversation to the bottom mid-read.

The animated aurora backdrop is a single
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
flutter test         # 449 tests, incl. crypto known-answer vectors
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

`flutter test` — **449 tests** across 40 files. Highlights:

- `noise_ik_test`, `noise_ik_session_test` — the IK pattern: two-message
  round trip, mutual authentication, that neither static key appears on the
  wire, that a caller with the wrong key gets no session and no reply, and that
  XX still runs unchanged alongside it
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
- `contact_card_test`, `contact_bootstrap_test` — the off-mesh first contact:
  card round-trip, tolerant parsing, tampered/forged-card rejection, and the
  relay introduction (announcement → `cc1:` content → frame → verified) with
  its `ttl: 1` point-to-point budget
- `channel_crypto_test`, `channel_invite_test`, `receipt_reaction_test`,
  `edit_delete_test` — feature wire formats
- `peer_id_test` — rotating ids: determinism, per-epoch change, the ±1 epoch
  acceptance window against boundary and clock skew, the reverse index
  (including roster invalidation and legacy ids), and store-and-forward draining
  mail filed under a previous epoch
- `mesh_ttl_test` — the density-scaled hop budget: monotonic in link count,
  never inflating a short ttl, and the decrement-then-cap a relay applies
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
- [x] **M6.5** — Contact cards: share the signed announcement as text, import a
      peer you've never met on the mesh, and introduce yourself over the relay
      so the reply path exists — a chat that never touches Bluetooth

---

## License

[MIT](LICENSE) © 2026 Kuzminyo
