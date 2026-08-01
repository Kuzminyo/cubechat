# Changelog

Every entry below is drawn from the git history — 198 commits, 2026‑05‑11 to
2026‑08‑01. Grouped by the milestones the project used internally (`M1`
through `M6`) and, once those tapered off, by theme. Newest first.

Current build: **0.6.3+36**.

---

## Android heat, and the first round of tester reports (2026‑08‑01)

- Android ran hot for reasons the iOS pass never touched. Two causes:
  **backdrop blurs that drew nothing** — `GlassCard` and every `MessageBubble`
  ran a full gaussian over the aurora, which is four soft radial gradients, so
  a screen of conversation paid a dozen blur passes per frame to reproduce the
  gradient it already had (measured before removal: max 11/255 per‑channel
  delta, mean 0.43/255) — and **BLE scanning at the active cadence on every
  screen**: `shouldScanActively` was plain `isForeground`, so reading a chat
  held the radio at a 71% duty cycle to refresh a radar nobody was watching.
  Now gated on the Nearby tab actually being on screen, read off `TickerMode`
  because the shell keeps every branch mounted for the session.
- Photo caption no longer flies up the screen when the keyboard opens: the
  caption island offsets itself by `viewInsets.bottom` and the `Scaffold` was
  *also* resizing for the keyboard, counting it twice.
- Deleting a 1:1 chat can now retract your own messages from the other device
  too, via the existing delete‑for‑everyone frame. Their messages stay — the
  wire format can withdraw ours and nothing can compel theirs.
- Diagnostics can share the log as a file. Copy‑all was the only way out, and a
  connection log is thousands of lines: the part that matters is never the part
  that survives a paste into a chat.

## Unreleased polish (2026‑08‑01)

- Contact profile actions replaced: the menu's Chat / Mute / Verify / Copy ID
  entries (all already reachable from the quick-action bar or the ID card
  below) gave way to four that weren't reachable at all — auto-delete chat,
  share contact, restrict copying, and remove from contacts. Block stays
  under the divider.
- Restrict-copying is enforced where it matters, not just stored: copy,
  forward and the system share sheet disappear together in the bubble menu
  and the media gallery.
- Shared Media and Voice messages sections on the contact profile, each with
  a count, opening a two-tab screen (photo grid → gallery, voice list).
- Contact profile capture test no longer flakes: it drew the real
  `AuroraBackground`, whose drift runs off a wall-clock `Stopwatch` rather
  than the test clock, so the backdrop landed at a different phase on every
  run (55% pixel drift on the background-heavy shot).
- Contact-card preview trimmed to a two-line head‑tail snippet (matches how
  fingerprints already read) with the ~275‑character payload behind a "Show
  full code" tap — nothing on the wire changes, only what the screen shows.
- Avatar entrance no longer replays on every row scrolled into view
  (`AppearOnce`): a lazily‑built list was re-triggering the fade‑and‑slide per
  row, mid‑scroll.
- Avatar remove button is reachable again — routing the profile cover's photo
  action straight to the picker had orphaned the screen that holds it.
- Full‑HD avatar storage (1920px) actually reaches the file now — the picker
  was still asking the gallery for a 1024px thumbnail underneath it.
- Contacts tab moved next to Chats (ahead of Nearby); added a pinned "Add
  contact" row and a new‑channel action, reusing the same dialog the Chats
  menu opens rather than a second copy.
- Chat list: dropped the "offline" pill (the avatar's online dot already says
  it), and moved the timestamp/unread badge into its own right‑hand column so
  it no longer drifts with name length.
- Fixed a real bug: renaming while no BLE peer was in range never reached
  contacts known only over the internet — two independent early‑returns
  (mesh‑heartbeat guard, once‑per‑process introduction cache) were quietly
  agreeing to do nothing.
- Profile header (avatar + name + actions) now rests as a compact bar and
  opens into a full‑bleed cover only on pull‑down or tap — the first cut had
  the photo filling the screen by default.
- Two disposal bugs surfaced by a widget test that finally opened the Nearby
  tab: `PeripheralController` read a provider inside `onDispose` (which a
  torn‑down container refuses, so the BLE advertisement never actually
  stopped), and `PeerDiscoveryController` left a closure holding `ref` on a
  scanner that outlives it.
- Performance pass: `FloatingGlass` gained a `blur` flag — chat/contact rows
  no longer each carry their own `BackdropFilter` (a full gaussian blur pass
  per row per frame) over a backdrop that is already a soft gradient. Avatar
  images now decode at the size actually drawn instead of at full‑HD
  regardless of a 44px circle. The profile cover's open/close animation no
  longer rebuilds the entire settings list underneath it.

## File transfer, avatars, privacy (2026‑07‑31 – 2026‑08‑01)

- Arbitrary file attachments: new manifest kind, chunk type, and — unlike
  photos and voice notes — files reassemble on **disk**, not in memory
  (25 MB mesh cap, 3 MB relay cap; the receiver streams the SHA‑256 check
  rather than buffering the whole thing).
- Sender‑supplied file names are sanitised before touching the filesystem
  (`safeFileName`) — untrusted input, so `../../` in a name doesn't choose
  where the file lands.
- Media captions: ride inside the existing signed manifest (new wire version,
  old manifests still decode byte‑identical) rather than a second message, so
  a photo+caption stays one bubble.
- New attach flow: a floating "island" category bar (Gallery / Camera / File)
  replaces the old single‑purpose picker sheet; picking photos now opens a
  full preview screen (pinch‑zoom, swipe between multiple picks, one‑tap
  editor, caption field) before anything sends.
- User avatars: pick a photo, stored locally, shown everywhere the identity
  gradient used to be the only option; a dedicated screen to view/replace it.
- Two privacy toggles in Profile: hide "last seen" and hide read receipts.
  Both are symmetric — hiding yours also stops you from seeing others' — with
  send‑side and receive‑side enforcement on each.
- Emergency Wipe, contact‑card codec, and the roster upsert path all updated
  to carry the new fields through.

## Store submission groundwork (2026‑07‑29 – 2026‑07‑30)

- Dropped the MIT license (proprietary going forward).
- Patent‑disclosure and grant paperwork generated and merged into a single
  numbered PDF, kept out of version control.
- Two promotional videos produced and cut; build artifacts excluded from git.

## Identity, IK handshake, transport hardening (2026‑07‑27 – 2026‑07‑28)

- Rotating peer IDs: the advertised identifier changes on a schedule instead
  of staying static, and the signed announcement that would have let an
  observer unmask the rotation was sealed.
- Noise **IK** handshake added alongside XX — a responder now refuses XX when
  it isn't in discoverable mode, closing the "hand our static key to whoever
  dials us" gap the IK work was written to fix. Handshake‑engaged state is
  now visible in‑app.
- Relay retry storm fixed; a redundant 124‑byte wrapper trimmed to the 101
  bytes it actually needed to carry.
- Wake service (APNs gateway for background delivery on iOS) designed,
  implemented, wired into the client — then removed. The design doc and the
  revert are both in history; the feature did not ship.
- Voice notes can be trimmed before sending, even after the recording is
  locked.
- Message sends now wait for the relay to actually accept the publish before
  the bubble reports "sent."

## Floating UI, mesh reach, cross‑platform delivery (2026‑07‑19 – 2026‑07‑27)

- Chat header and composer rebuilt as floating glass islands (matching the
  bottom nav's treatment) instead of app‑bar‑owned bands; messages gained
  swipe‑to‑reply and double‑tap‑to‑react.
- Starting a chat no longer requires ever having been in Bluetooth range —
  the Nostr relay path can carry the first message; channels now reach
  members who are off‑mesh too.
- Mesh hop budget scales to how dense the local link graph actually is,
  instead of a fixed TTL.
- Photos and voice notes now send over the internet fallback, not only over a
  live BLE session; a stale BLE session falls through to the relay
  automatically.
- iOS: background fetch (`BGAppRefreshTask`) added so relay messages can
  arrive while backgrounded; notification permission requested on launch and
  the delegate wired so iOS actually surfaces them.
- Duplicate history stopped; pinned messages, presence, and read timestamps
  added.
- CI iOS builds moved to macos‑15/Xcode 16 so `camera_avfoundation` compiles;
  in‑app camera capture, a photo editor, and tap‑to‑view landed.

## Thermal and radio tuning (2026‑07‑16 – 2026‑07‑26)

- Multiple passes at the same problem: the app was keeping phones warm.
  Fixed a peripheral‑mode bug where advertising silently never started; fixed
  fragmented BLE frames being dropped whenever the phone was the peripheral;
  capped ProMotion, honoured the background‑mode toggle, stretched the idle
  scan cycle, and eventually added a proper backoff so the idle scanner
  doesn't spin at full cadence when nobody has been nearby for a while.
- The UI itself was made to go idle: animations and repaints stop when
  nothing is happening on screen (this pattern — a `ValueListenable` gating
  tickers — is what several 2026‑08‑01 performance fixes above also lean on).
- Read markers, favourites, and relay settings had a race that could wipe a
  Hive box on close; fixed alongside a scanner spin‑loop when Bluetooth was
  off.

## Nostr fallback, groups, and messenger‑feature merge (2026‑07‑10 – 2026‑07‑19)

- **M6**: Nostr relay client (NIP‑01 over WebSocket), BIP‑340 secp256k1
  signing, the peer announcement extended to carry a signed npub, and the
  whole fallback wired end‑to‑end into send/receive — the point at which the
  mesh stopped being the *only* transport.
- Group channels, message edit/delete, read receipts, and reactions landed in
  one large UI overhaul, alongside per‑chunk forward‑secret media encryption.
- Reply/quote (compose bar, long‑press action, quoted bubble in the
  timeline).
- Block/mute for peers.
- A long‑running feature branch (`messenger-features`) merged back into
  `main`, bringing the iOS build in step with what the Android APK already
  had.

## Foundation: mesh transport, crypto, persistence (2026‑05‑11 – 2026‑05‑23)

The initial seven‑week build, milestone by milestone:

- **M1 / M1.5** — BLE central scanning, peer discovery UI, and native
  peripheral mode (Kotlin + Swift) so two phones can find each other at all.
- **M2.A / M2.B** — Identity keys and a real Noise XX handshake; encrypted
  messaging between two peers over BLE.
- **M3.A–F** — The mesh transport layer proper: an envelope format
  (origin/dest/msgId/TTL), a dedup cache, signed peer announcements,
  SealedBox end‑to‑end encryption, multi‑hop forwarding, and mesh‑only peers
  surfaced in the Chats list.
- **M4** — Chat history and the known‑peers roster persisted across restarts
  (encrypted Hive storage).
- **M5.1–M5.4** — Editable nickname broadcast over BLE, Emergency Wipe
  (triple‑tap the logo), slash commands, and end‑to‑end image transfer over
  the chunked‑media pipeline (voice messages followed the same path).
- Forward secrecy core (X3DH + prekey store) wired into the text path; replay
  protection via authenticated timestamp; short messages padded to defeat
  length‑based traffic analysis; chat history encrypted at rest.
- Store‑and‑forward: an opportunistic relay buffer for offline recipients,
  persisted across restarts, with automatic delivery once the recipient's
  Bluetooth returns.
- Background mode (foreground service keeps BLE alive), notifications for
  incoming messages, online/offline presence.
- Nav bar and visual identity iterated repeatedly in this window — the
  floating glass pill treatment used everywhere today (nav bar, chat rows,
  contact rows) was arrived at here, several redesigns in.
- CI: unsigned iOS IPA builds on GitHub Actions; Windows portable
  zip/installer scaffolding.

---

*Generated from `git log`, not hand‑maintained — regenerate by walking the
history again rather than editing entries in place, so it stays honest.*
