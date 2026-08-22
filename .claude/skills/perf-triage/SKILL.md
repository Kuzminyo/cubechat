---
name: perf-triage
description: How to diagnose heat, battery drain, lag, stutter or jank in cubechat before changing anything. Load when a report mentions the phone getting warm, the battery draining, the app feeling slow, frames dropping, or when considering a performance optimisation.
user-invocable: true
---

# Diagnosing cost in cubechat

Two full rounds of optimisation in this repo were argued from reading the code,
and both times the expensive thing was not the thing that looked expensive. The
tools below exist because of those two rounds. Use them before proposing a fix.

## Ask which question is being asked

"Hot" and "laggy" are different problems with different instruments, and reaching
for the wrong one is how a round gets wasted.

| Symptom | Instrument | What it answers |
|---|---|---|
| Battery drains overnight, phone warm in a pocket | **Android's own battery screen**, per-component | Where wall-clock time went across the whole process |
| Scroll stutters, animation hitches | `FrameStats` (Diagnostics screen) | Cost of a frame, split UI thread vs GPU thread |
| Warm while frame numbers look healthy | `CpuProbe` (Diagnostics screen) | Per-thread CPU off `/proc/self/task/<tid>/stat` — BLE, sockets, Hive, platform channels |

**Ask for Android's battery screen first when the report is about battery.** The
in-app panels answer stutter, not drain. The measurement that settled it: GPS was
1h47m of wall time against 7 minutes of total CPU. Blurs and signature work were
not the cause, however plausible they looked.

## The two threads are not interchangeable

`FrameStats` splits every frame into:

- **build** — the UI thread, Dart. Widget rebuilds, layout, provider churn, image
  decodes, anything synchronous in `build()`.
- **raster** — the GPU thread. Blurs, gradients, overdraw, `saveLayer`, shader
  compilation. Almost none of it is visible in Dart at all.

A phone with raster at 14 ms and build at 2 ms will not get one degree cooler
from removing work in `build()`, however real that work was. Read the numbers
before deciding which column you are optimising.

## Get the log before it evicts itself

`DebugLog` holds **200 lines** and one photo batch fills it. Ask for the log
immediately after the failing action, before any media is sent — otherwise the
evidence has already been pushed out by chunk lines.

## What has already been done

Do not re-propose these; they are in the tree.

- Aurora on a ~30 fps wall-clock ticker, paused while backgrounded, single
  `CustomPainter`
- Online dots parked via `UiActivity` instead of ticking forever
- BLE scan duty cycle and idle scan gap
- ProMotion held to 60 Hz on iOS via `CADisableMinimumFrameDurationOnPhone`
- Blur sigma 30 → 14, `BackdropFilter`s grouped
- `Image.file` decodes capped to the drawn size; gallery thumbnails sized
- Presence beacon cadence reduced; GPS parked when the beacon reaches nobody
- Signature work off the hot path; read receipts batched instead of per-message
- Map rebuilt once per stop rather than four times per resume

## What has been tried and reverted — read the comment first

Each of these is recorded next to the constant it concerns. Reverting is only
half the lesson; re-proposing it is the failure this section exists to prevent.

- **`FlutterDisplayMode.setLowRefreshRate` on Android** (2026-08-17, reverted
  within the hour). The arithmetic looked sound: raster p90 was 9.6 ms, inside a
  60 Hz budget, so half the frames should have been half the work. On the phone
  it was the opposite — build p90 4.7 → 7.8, raster 9.6 → 14.8, reported as
  barely usable. Whatever that device does in the low mode, it is not "the same
  frames, fewer of them". The app **asks for the high refresh rate** on Android
  on purpose: MIUI leaves an app that states no preference at 60 Hz while the
  system UI runs at 90, and uneven pacing reads as stutter even when no frame is
  missed. See `_matchDisplayRefreshRate` in `lib/main.dart`.
- **Blur sigma 9** (2026-08-17, reverted) — shipped in the same build as the
  above, so it was never measured on its own. If it is lowered again, do it
  alone. See `lib/core/theme/glass.dart`.
- **An animation-polish branch** (2026-08-17) — written and deleted. Fix measured
  lag before any "make it feel better" pass, and animate what every touch does
  rather than what happens rarely.
- **LZ4 payload compression** — deliberately dropped from the roadmap. It defeats
  the length-hiding padding and is a CRIME/BREACH-class leak under encryption.

## Rules

1. Measure first, name the number, then change one thing.
2. Change one thing at a time. Reverting one unverified change while another sits
   on top of it is not a revert.
3. Write the measurement into the comment above whatever you changed, including
   when you revert — that is what makes the next round cheaper.
