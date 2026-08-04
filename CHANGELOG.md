# Changelog

Every entry below is drawn from the git history — 198 commits, 2026‑05‑11 to
2026‑08‑01. Grouped by the milestones the project used internally (`M1`
through `M6`) and, once those tapered off, by theme. Newest first.

Current build: **0.14.0+59**.

---

## A back button while something is playing, and files that can be asked for again (2026‑08‑04)

- **The playing-voice bar had eaten the header.** The two took turns in one
  capsule, swapped by a downward swipe — so while anything was playing there
  was no back button on screen and nothing saying it was a gesture away. The
  bar has its own island now, under the header and under the pinned bar when
  there is one, and the conversation pads itself to whatever that column
  measures.
- **Tapping the app-wide voice bar threw every time.** It lives in the app's
  `builder`, which sits above the router that provides `InheritedGoRouter`, so
  `context.push` found no GoRouter — an exception into the zone and a bar that
  appeared to do nothing. It is handed the one push it needs now.
- **A file cleared from disk can be asked for again.** A received file lives on
  the receiver's phone and nowhere else, so clearing the transfer centre left
  bubbles pointing at paths that no longer existed, unopenable for good.
  Tapping one now asks the sender — a new `mediaRequest` payload carrying the
  16-byte media id — and they answer from their own outbox copy under the same
  id, so the original bubble adopts the file instead of a duplicate appearing
  beneath it. 1:1 only: a room has no single person to ask.
- Both ends need this build for the re-request to work, and neither is worse
  off without it: an older peer ignores a payload type it does not know.

---

## Folders you asked for, a swipe between tabs, and a notebook with contents (2026‑08‑04)

- **The four filter pills are gone from the default list.** They shipped on
  whether or not anyone wanted them — a permanent strip of chrome between the
  search field and the first conversation, on the screen that opens the app.
  Folders are opt-in now: Unread, Direct, Channels, Favorites, Reachable,
  switched on from ⋮ → Folders (or the `+` at the end of the row once there is
  one). They are cuts of the same list rather than places chats are moved to,
  so nothing has to be filed and a chat leaves Unread by being read. Switching
  off the folder you were viewing releases the list rather than leaving it
  filtered by a pill that is no longer there.
- **A flick sideways changes tab**, the way it does in Telegram. Deliberately a
  fling rather than a drag the content follows: the four branches are an
  IndexedStack with their own live scroll positions, and dragging them across
  each other would mean giving that up. It listens for pointer events instead
  of competing for them, so swipe-to-reply and any other in-screen gesture win
  as before.
- **The favourite star moved** out of the name row and into the bottom-right
  corner of the tile, small, beside the unread badge. Next to the name it was
  one more thing pushing the name around in a row that already carries a
  verified tick and a transport pill.
- **Channels wear a loudspeaker instead of a hash** — in the tile, the avatar,
  the forward sheet, the contact card and the channel info header. The avatar
  in particular was a circle containing "#": the punctuation its own id starts
  with, and the least informative character in the name.
- **Saved has a profile.** Tapping its header opens the shared-content screen a
  contact has — Media, Voice, Files and now **Links**, a new tab everywhere it
  appears. Links are not a message kind, so they are found rather than
  filtered, and the matcher is deliberately narrow: a Links tab full of "3.5mb"
  is worse than an empty one.

---

## Twelve megabytes over the internet, and photos that arrive as they left (2026‑08‑03)

- **The internet ceiling went from 3 MB to 12 MB.** What capped it was never
  bytes but publishes: every chunk is one relay event and one round trip, and
  relays rate-limit — a limit that lands on ordinary messages too. The relay
  chunk is 32 KiB now instead of 16, so the same ~190 publishes that used to
  carry three megabytes carry six, and twelve costs ~380. 32 KiB is the
  ceiling, not a round number: a chunk goes out as `"cc1:" + base64(frame)`,
  which puts it at ~44 KB of event, comfortably inside the 64 KiB most relays
  accept and refuse just past. A test pins that arithmetic, along with the
  receiver's reassembly cap and the protocol's chunk-count limit.
- **⚠️ Both phones need this build** to send a file over the internet: a 32 KiB
  chunk arriving at an older build is rejected as malformed, and the transfer
  stalls. Bluetooth is unaffected — chunks are sized to the link's MTU there
  and always have been.
- **Photos can be sent as files, uncompressed** — Telegram's "send without
  compression". The preview screen has an **Original** toggle; with it on, the
  asset's own file goes out through the file path, byte for byte, checked
  against the manifest's signed hash on arrival. The photo path exists to fit a
  picture through Bluetooth, which is the right trade for a snapshot and the
  wrong one for a document photographed to be read — the text is the first
  thing the encoder spends. The brush stands down while Original is on, since
  an edit is the one thing that would have to be re-encoded.
- The two "file is too large" messages now carry the number from the constant
  that produced them, so the advice and the ceiling cannot drift apart again.

---

## A size you can choose, and a notebook that stops pretending to be a room (2026‑08‑03)

- **The interface has a size setting.** The same build lands visibly larger on
  one phone than another — Android's Display size and iOS's Larger Text both
  feed the text scaler, and neither is visible from inside the app. Profile →
  Застосунок now offers System / Smaller / Normal / Larger, with a sample line
  underneath so the choice is made by looking. Following the phone stays the
  default: someone who made every app bigger meant this one. An override is
  clamped like the platform value, because a setting that can break the layout
  is not a setting — and the buttons that set it never scale, so the way out is
  reachable from every choice.
- **The profile name no longer lands on the buttons under it.** With the cover
  photo open, the name and the discoverability line are positioned from the
  bottom of the header, and that offset was a constant measured at the stock
  font size. On a phone asking for larger text — an iPhone especially, where
  the default already runs bigger — the block grew down into the action row.
  It is measured against the real scale now, and a test pins the invariant at
  three of them.
- **Saved notes stopped borrowing things a room needs.** No poll composer (no
  voters), no invite button (nobody to invite), and no route indicator (nothing
  is sent — a globe over a notebook claims the opposite of the truth). Tapping
  the name opened channel info for a room called `saved`, which not only showed
  a room that does not exist but *created* one on the way in: the info screen
  registers you as a member of whatever name it is handed.
- **And it has its own mark**: a bookmark on the identity gradient rather than
  the first letter of its own title, which said nothing except which language
  the app was in — the same notebook was a "З" in Ukrainian and an "S" in
  English.

---

## A palette that reaches the whole app, every emoji, and a room that reaches everyone in it (2026‑08‑03)

- **Choosing a colour now recolours the interface, not the accents on it.**
  Every pane of glass in the app was `Colors.white` at some low opacity, so a
  palette moved the buttons and the aurora and left the app the same grey it
  always was. White is now a palette value (`AppColors.glass` / `.ink`) pulled
  toward the theme's tint, and the ~100 call sites that hardcoded it were
  converted. Three palettes join the five: **Fuchsia** (pink on near-black),
  **Violet** and **Ocean**. Graphite deliberately keeps a neutral white — it is
  meant to be the colourless one. The swatch in Settings now shows the
  background with the brand over it rather than the brand alone.
- **Reactions are no longer six emoji chosen in the source.** The strip on the
  long-press menu ends in a `+` that opens the full system emoji sheet —
  eight categories, everything the platform font can draw. Whatever you pick
  joins the strip, so the row converges on your own habits, and a double-tap
  leaves whichever emoji you reached for last (a heart until you change it).
- **A jump lands somewhere visible.** Tapping a quote or the pinned bar drew a
  2‑pixel ring around the bubble; it now washes the whole row edge to edge and
  fades, the way Telegram marks it — a ring reads as "this message is
  special", a band reads as "you were brought here". The jump also finishes on
  the message it was asked for: it used to scroll to whichever message was
  *pinned*, whatever the destination was, which put a tapped quote near its
  target rather than on it.
- **A member of a room relays the room.** A channel post went over the relay to
  the author's own known peers and no further; a member who received one
  re-emitted it over Bluetooth only. In a three-person room where two members
  had never met each other directly — both invited by the third — that is
  exactly the reported bug: you see everything one of them writes and nothing
  from the other. Members now carry room frames onward over the relay too,
  ttl-decremented, terminating on the dedup every node already applies.

---

## A search screen, and a nav bar that stays put (2026‑08‑03)

- **The keyboard pushed the floating nav bar up instead of covering it**, so
  tapping the chat search left a nav bar sitting in the middle of the screen.
  The bar is an overlay pinned to the bottom of the shell's `Scaffold` body,
  and `resizeToAvoidBottomInset` defaults to true — the body shrank by the
  keyboard height and took the bar with it. Off now: nothing in a tab branch
  needs the resize (every field in one is at the top), and the screens with
  low-sitting inputs are pushed routes with their own Scaffolds.
- **Tapping search opens a screen** rather than filtering in place. With
  nothing typed there is something worth showing — a row of the people you
  actually talk to, and the chats you last looked up — and neither fits above a
  list already full of chats.
  - The row puts favourites first, because that is the user stating who matters
    and nothing inferred from traffic should outrank it; the rest fills by how
    much has been said, which is steadier than recency (recency is just the top
    of the chat list one screen back). Channels are excluded — the row is
    faces, and a channel has none.
  - "Recent" is its own stored list of chats opened *from search*, not a read
    of the existing read markers. Those would give a plausible order for free
    but the wrong list, and the "Clear" button beside it would have to either
    lie or wipe the state unread badges depend on. Cleared by Emergency Wipe
    too — who you went looking for is its own trace.

## Read receipts in channels (2026‑08‑03)

Asked for in the first round of tester feedback: *«добавить в каналах надо типо
кто прочитал во сколько»*. 1:1 chats have had read state all along; channels
did not, because `InnerPayloadType.receipt` was excluded from them on both
sides — `sendReadReceipts` returned early for a `#` chat, and the ingest switch
lumped `receipt` into a catch-all "not carried in channels" list whose comment
justified the *other* entries and said nothing about this one.

**No wire format change.** `ReadReceipt` already carries only msgIds; who sent
it comes from the signature on the channel frame, exactly as authorship and
reactions already do. `_handleChannelBody` was in fact already deriving both
the reader's fingerprint and their display name before its switch — everything
needed was sitting there unused.

The shape is dictated by a fact about channels: **there is no member roster.**
Holding the key is membership, joining tells nobody, and a message goes out as
a blind broadcast. So there is no denominator — "3 of 5" is unknowable — and
the honest answer is the list of people who said they read it. That makes the
state additive and per-reader, which is the same problem reactions already
solved, so `readBy` follows `reactions`: a map on the message, merged
idempotently, capped (64 readers) so a peer minting signing keys cannot grow
one message without limit.

A repeat receipt keeps the **first** timestamp. Mesh and relay both redeliver,
and a duplicate means the frame was sent again, not that they read it again.

Times are our own clock, matching the existing 1:1 `readAt` for the same
reason: a timestamp from the other side is neither trustworthy nor comparable
with the rest of the timeline. Names are stored beside them rather than
resolved at render, the way `authorName` already is.

Surfaced as a "read by N" chip under your own channel messages, with the names
and times one tap away in the details popup that already answers "sent at /
read at". Worth knowing: a silent channel member is invisible today until they
speak — reading now makes them visible.

## The logo that hung, on Android (2026‑08‑03)

Fully closing the app and reopening it could leave the launch logo on screen
for a long time, sometimes taking several attempts — Android only.

Android holds the launch theme until the first Flutter frame, and `main()`
awaited four things before `runApp`. Anything that stalls there does not look
like a slow feature; it looks like an app that will not open. One of those
four steps was `flutter_displaymode`, added two builds ago, guarded to Android
— which is exactly the platform the symptom appears on, and it has no business
gating a frame, since the panel changing mode a moment later is invisible. It
now runs after `runApp`, unawaited.

The rest of the path is bounded rather than trusted: each step has a time limit
and starting without it beats not starting. The boot line also moved to the
very first statement — it used to sit after Hive and notifications, so a hang
left no log at all — and any step slower than 250 ms now records how long it
took, so the next report can name the step instead of the symptom.

## Hiding your last seen now says "offline" instead of nothing (2026‑08‑03)

Turning the switch off made contacts show you *permanently online* — the
opposite of the promise — and leaving the app never corrected it.

Silence was the obvious reading of "don't share my presence" and it was the
wrong one. A peer with no beacon to go on falls back to "did they announce
recently", and announcements are not presence: they are not gated by this
setting and over a relay they never stop. The goodbye was suppressed by the
same rule, so closing the app could not fix it either.

The hider now asserts `offline` rather than falling silent. It is also the
honest meaning of the setting — others see you as not‑online and never learn
when you were — it costs nothing extra, since the heartbeat that carried
"online" now carries "offline", and because a fresh beacon outranks that
fallback, a 45 s heartbeat inside a 150 s TTL keeps the answer pinned. Flipping
the switch pushes a beacon immediately rather than waiting out a heartbeat,
because turning it off is something people do precisely when they want to stop
being visible.

## A 512 px avatar, and one relay fewer (2026‑08‑03)

- **Dropped `wss://relay.damus.io` from the defaults.** Two device logs had it
  answering `rate-limited: you are noting too much` to very nearly every
  publish, and dropping its socket between times. It cost a third of every
  fan‑out to store nothing. Changing the default alone would have reached
  nobody — the stored list wins, and enabling the fallback writes one — so a
  one‑time migration prunes it from saved lists, behind a flag that leaves it
  alone if a user adds it back deliberately.
- **The big circle is no longer chewed.** The shared copy is now sized from the
  largest place it is drawn: the profile hero is `width * 0.48` ≈ 173 pt, which
  is 518 physical pixels at 3x, so 128 and then 320 were both upscaling. Now
  512, with quality and then size stepped down until the bytes fit.
- **The previous ceiling was undeliverable.** 48 KB is above what the BLE
  fragmenter can carry: a conservative 185‑byte ATT MTU allows 255 slices of
  167 bytes = 42,585 bytes total, less ~192 for the envelope, SealedBox and
  signature. A frame over that is not slow, it cannot be split at all. The
  sender now fits a 36 KB budget by construction and the receiver accepts up to
  40 KB; a test pins both against the fragmenter's own constants.

## Avatar round two, and a toggle that meant the opposite (2026‑08‑02)

Avatars now arrive — the tester's log has `[AVATAR] stored 5662B` on both
phones — which turned up the next three things about them.

- **Removing your avatar left it on everyone else's phone.** The announcement
  carries a digest of the picture and nothing re‑announced when that digest
  changed, so a new picture waited for the next heartbeat and a *removed* one
  never propagated at all: the announcement saying "no picture" is the only
  thing that tells the other side to drop what it cached. The picture now has
  the same watcher the nickname has had.
- **The shared copy was sized for a 44 px row** (128 px), and the contact
  profile draws it at ~200 pt — 600 physical pixels on a 3x phone. Now 320 px
  at quality 82, with the payload ceiling raised to 48 KB, which stays under
  the fragmenter's hard limit of 255 × ~230 B ≈ 58 KB.
- **Hiding "last seen" made everyone permanently online.** The toggle is
  symmetric, so with it on no beacon arrives — and `peerIsOnline` then fell
  through to "did they announce recently", which over a relay is always yes,
  because announcements refresh `lastSeen` and never stop. Having chosen not to
  know, it now says so instead of guessing, and the header reads "status
  hidden". A live Noise session still counts: nobody had to tell us about that.
- Shared **Files** section on the contact profile, beside Media and Voice, and
  a third tab on the content screen. Reuses the file bubble rather than
  re‑describing a file, so naming, sizing, the icon and the tap behaviour stay
  in one place.

## What two device logs turned up (2026‑08‑02)

- **A sealed introduction over Nostr was never read.** `_announcementFrame`
  stamps every announcement — sealed ones included — with `broadcastDest()`, so
  the `_isAddressedToMe(env.destPubkeyHash)` check that decided whether to open
  it could never be true; and since a relay introduction rides at ttl 1, the
  forward it fell through to died immediately. The tester's log shows exactly
  that: the frame arriving and going straight back out as "ttl exhausted", with
  no registration between. Now decided by whether the SealedBox opens, which is
  the only thing that actually answers the question. This is why an avatar
  digest never landed off‑mesh, and it could swallow a rename too.
- **Files crawled over the relay because a publish waited for every relay to
  answer.** One acceptance is delivery — the event is stored and the recipient's
  subscription finds it. The log has chunks landing ~300 ms apart with
  damus.io refusing nearly all of them as `rate-limited`, i.e. a 1 MB / 63‑chunk
  transfer pacing itself against relays that were never going to store it.
  Refusal still waits for the full count, because "everyone refused" is only
  knowable once everyone has spoken. The 15 ms BLE notify pacing is also skipped
  when the relay is carrying the transfer; it exists for a notify pipe.
- **Presence stopped flapping.** `inactive` was already excluded, but Android
  reports a full `paused` for the file picker, the camera and the share sheet —
  so sending one screenshot produced goodbye/hello pairs seconds apart, each
  fanning out to every contact on every relay (four flips in fifteen seconds in
  the log, and a share of the rate‑limiting above). The goodbye now waits out a
  6 s grace and is cancelled by coming back.
- **"Last seen" means when they left, not when they arrived.** A goodbye beacon
  refreshes `lastSeen` too — it is the last thing they did. Safe because
  `peerIsOnline` gives a fresh beacon precedence, so they still read as offline,
  now with a timestamp that means something.
- **Auto‑delete takes any duration**, not four fixed choices: presets stay as
  shortcuts and a custom entry takes a number plus a unit. Values stored under
  the old enum names are still read, so an update cannot quietly switch
  somebody's auto‑delete off. A timer icon now sits beside the name in the chat
  header when the conversation is set to forget.

## Avatars actually reach other people (2026‑08‑02)

Until now an avatar was a local decoration: `avatar` appeared nowhere in
`lib/core/transport/`, so a picture never left the phone that set it and
everyone saw everyone else as a generated gradient. The transfer is a hash in
the announcement plus a picture on request:

- **Announcement v0x05** appends a 32-byte SHA-256 of the sender's avatar, all
  zero for "no picture". Only the digest is broadcast — the picture is
  kilobytes and the announcement rides a heartbeat to every peer in range, most
  of whom already have it. It sits *inside* the existing signature, which is
  what makes the picture trustworthy later. v0x04 still decodes, and is
  distinguished from "no picture" (`isAvatarAware`) so an older peer's silence
  never deletes an avatar we hold.
- **Pull, not push.** A receiver that sees a digest it has no bytes for sends
  an `avatarRequest`; the answer is an `avatar` payload carrying a 128 px JPEG
  (~4 KB, under the fragmenter's ceiling several times over). Requests are
  marked per `peer:hash`, so a heartbeat arriving from six mesh neighbours asks
  once, and a *changed* picture asks again.
- **The bytes are bound to the digest their owner signed.** They travel by a
  different route than the promise, and `PeerAvatarsController.store` refuses
  anything that doesn't hash to the announced value — otherwise whatever could
  deliver a frame could choose what a contact's face looks like.
- Received pictures live in their own Hive box, not on the roster: that map is
  read whole on load and rewritten on every `lastSeen` touch, and a few KB of
  JPEG per contact would have ridden along with each one. Cleared by Emergency
  Wipe and when a contact is deleted.
- Fixed a latent contact-card bug this exposed. `_extractToken` runs to the
  first non-base64 character, so "…card\nsee you" hands back the card plus
  "seeyou" — every letter of which is legal base64. Whether that still decoded
  was pure arithmetic about where the announcement's length fell relative to
  the 4-character group boundary; it survived a v0x04 card and broke on the 32
  bytes v0x05 added. The tail is now shaved back to a boundary that decodes.

## Rename over the relay, 90 Hz, opening files (2026‑08‑02)

- **A rename never reached anyone off‑mesh, on the phones where that was the
  only way to reach them.** `announceNow()` is the only thing that pushes a new
  nickname over the relay, and the listener that calls it was registered inside
  `_bootPeripheral` — which sits behind four early returns (not mobile, no BLE
  support, permission not granted). Deny the Bluetooth permission and the
  listener was never wired at all, so renaming yourself was invisible to your
  contacts until one side reinstalled. Now registered ahead of every bail‑out,
  because a rename is not a Bluetooth event.
- Android asks for the panel's real refresh rate (`flutter_displaymode`). MIUI
  leaves an app that states no preference on 60 Hz while the system UI around
  it runs at 90, so every scroll was a 60 Hz animation on a 90 Hz panel — uneven
  pacing, which reads as stutter even when no frame is missed. iOS deliberately
  untouched: it is held at 60 Hz for heat.
- Tapping a received file opens it instead of offering to send it onward. The
  share sheet answers "who else should get this?"; a tap is asking "what is
  it?". Sharing remains, one level down, and is offered as the fallback when
  nothing installed claims the type.
- Test suite no longer depends on the wall clock: `chat_tile_layout_test`
  pinned a calendar date against a formatter that only renders HH:mm for the
  current day, so it passed on the day it was written and failed every day
  after.

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
