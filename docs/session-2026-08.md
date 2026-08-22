# Session notes — August 2026

What changed, what is still open, and the three times a conclusion turned out to
be wrong. Kept because most of the cost here was not writing the fixes; it was
finding out which thing to fix.

Builds 0.46.1 → 0.50.1.

---

## The one that matters: heat was never where we looked

Three rounds of performance work aimed at the wrong column.

| Round | Aimed at | Outcome |
|---|---|---|
| Blur radius, display refresh rate | GPU | **Reverted.** Refresh rate made it worse: build p90 4.7 → 7.8, raster 9.6 → 14.8. |
| Nostr signature cost | CPU | **Kept.** Real: frames over budget went 62% → 4%. |
| Android battery screen | — | **The answer.** GPS 1 h 47 min against 7 min of CPU. |

Seven minutes of CPU across six and a half hours. Every in-app panel in this repo
measures something that was never the battery cost.

**The rule that came out of it:** for heat or battery, ask for **Android's own
battery screen first** (Settings → Battery → cubechat). It is the only source
that sees GPS, radio and screen. The in-app panels answer "why does it stutter",
which is a different question that was mistaken for this one three times.

The GPS itself was two bugs and one intrinsic cost:

- **Fixed.** The position stream ran whenever the share switch was on and the
  map-friend list was non-empty — neither means anybody is *receiving*. A friend
  whose pubkey no longer resolved failed every send while the radio ran on. Now
  three empty rounds park it; one successful send un-parks it.
- **Fixed.** A stationary phone re-published an identical position every 45 s
  against a 2-minute TTL. The repeat check compared coordinates rounded to four
  decimals (~11 m) — GPS jitter indoors is larger than that, so it never once
  fired. Compared by distance now, 40 m, matching the stream's own filter.
- **Intrinsic.** A live location shared to reachable friends needs a continuous
  fix with a foreground service; Android throttles background one-shots. The
  remaining lever is the share switch.

## Signing was 4 scalar multiplications of pure-Dart BigInt

Every Nostr event carries a BIP-340 Schnorr signature over secp256k1, implemented
in-repo because the crypto stack has no such curve. The arithmetic was affine —
a modular inverse per doubling *and* per addition, about 1500 extended-Euclid
runs on 256-bit BigInts per event — run synchronously on the frame-building
thread, one event per recipient, in bursts of fifteen a second.

Jacobian coordinates take the inverse out of the loop:

```
sign    27.9 ms  →  9.7 ms
verify  13.9 ms  →  4.1 ms
```

Pinned by the seventeen official BIP-340 vectors, which passed before and after.

Levers left, in order: drop the self-verify inside `sign` (another 2×, but it is
a security self-check — ask first), a precomputed comb for G, then moving
signing off the UI isolate.

## Two storms

Both found in shared logs, both the same shape: a retry with no floor.

**Read receipts.** An iPhone with no internet produced 200 log lines covering
twenty seconds, entirely `no route for N read ack(s) — will retry ×172`. Hundreds
of attempts per millisecond. The sweep walks every chat and had no re-entry guard
and no gap between passes; inside a chat the slice loop carried on to the next
twelve ids after the first found no route. Now: one sweep at a time, at most one
per five seconds, and the first sliced failure ends that chat's pass.

That storm is also why no Bluetooth line survived in that log — it evicted the
whole 200-line ring buffer in seconds.

**Map surface rebuilds.** My own, added the day before: the resume handler
recreated the native GoogleMap on every `resumed`, and Android emits those in
bursts — four inside three seconds while backgrounding. Now only a real
`paused`/`hidden` arms a rebuild.

## Fixed, by area

**Photos**
- Albums are per sender, so two people sending at once no longer shred each
  other's batch into single bubbles.
- A batch carries a local `albumId`; a second batch does not glue onto the first.
- Inbound batches split on pace (4× the run's median gap, floor 45 s) because a
  sentence between two batches arrives *before* them and cannot separate them.
- Send progress ring on photos, voice notes and files.
- No border on a photo bubble — the stroke paints inside the container, so the
  picture sat a pixel in and its square corner was clipped at the outer radius,
  breaking the line in every corner.
- Gallery thumbnails decode to the cell's real width. They were 240×240 bitmaps
  in ~120-point cells: four times the pixels, on the screen that scrolls
  hundreds of them.

**Chat**
- Reply focuses the composer, so the keyboard rises with the quote.
- Send animation fires every time (bubbles keyed by message id).
- Double-tap reacts anywhere on the row, not only on the painted bubble.
- Floating day chip follows the scroll.
- Auto-delete counts from when it was switched on — it used to wipe the last
  year of a conversation the instant you enabled "delete after an hour".

**Chats list**
- Archive can be hidden (hold the row; the switch in Customisation brings it
  back, and the toast says so).
- Selection, pin, mute and delete work inside the archive.
- Folder bar 40 → 34 points; island shadows removed everywhere.
- Header softens into the aurora when there is no folder row — and does it in
  its own gradient, not with a strip that pushed the first chat down.

**Saved Messages**
- Emoji tags with a filter bar.

**Map**
- Survives being swiped out of recents (the process lives, the Activity's
  surface does not — the platform view is recreated by key).

**Editor / stickers**
- Filter icon is a photo filter, not a funnel. Saturation is not a water drop.
  The circle in the shape row is an outline like its neighbours.
- Stickers have a visible delete badge, not only a long-press.

**Diagnostics**
- CPU-by-thread panel, from `/proc/self/task`, sampled off the UI thread.
- Stall count and worst frame — p90 cannot show a freeze, and "подфризує" kept
  arriving next to healthy percentiles.
- Window labels: the avg/p90 lines are the last ~180 frames, the counts are the
  session. Printed together unlabelled, "p90 18.6 ms" was read as a verdict on
  3013 frames.

## Reverted

**Noto Color Emoji.** 10 MB, named as the fallback behind every text style,
which makes the engine consult a large colour font while shaping any text at
all. iOS came back with lag everywhere in the first build that had it. Removed
whole.

If the emoji are worth another attempt: not a global fallback. A subset built
from the characters the picker offers, applied only where emoji are drawn.

## Still open

- **Back gesture.** Reported as "the same one as before" — never narrowed to
  which failure: does not fire, fires on an ordinary scroll, or returns to the
  wrong screen.
- **BLE connect latency** ("seven seconds"). Every log so far shows Bluetooth
  *working*: `central connected` → Noise handshake in ~100 ms → ~9 KB/s. But in
  all of them this phone only ever *accepted* a connection; there is no
  `[BLE-CENTRAL]` line anywhere. The log has to come from the phone that fails
  to connect.
- **iOS lag.** May have been the receipt storm or the emoji font, both now gone.
  Needs a measurement on the new build; the stall line answers it in one look.
- **Album grouping across devices** would need the batch id on the wire. The
  manifest is versioned and old builds reject unknown versions, dropping the
  media entirely — so it is a compatibility change, not a field addition.

## How to read a report here

1. **Heat or battery** → Android's battery screen, not the app.
2. **Stutter** → Diagnostics, "measure another screen for 45 s", then use it.
   `p90` says how often a frame is late; the stall line says whether anything
   actually stopped.
3. **Anything with a specific event** → ask for the log *immediately after that
   event and before sending any media*. The buffer is 200 lines and one photo
   batch fills it.
4. **A screenshot beats a description** for anything visual. Half the icon
   problems here were not the glyph but what sat next to it.
