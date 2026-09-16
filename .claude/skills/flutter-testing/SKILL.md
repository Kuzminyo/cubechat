---
name: flutter-testing
description: Running and writing tests in the cubechat Flutter repo. Load when running the suite or a single test, diagnosing a failing or flaky test, writing a widget test that needs Riverpod overrides or Hive, dealing with golden/design-QA captures, or reading flutter analyze output.
user-invocable: true
---

# Testing cubechat

143 test files under `test/`, flat — no subdirectories except `support/`.

## Running

```bash
flutter test
```

```bash
flutter test test/mesh_ttl_test.dart
```

```bash
flutter test test/mesh_ttl_test.dart --plain-name "the cut is a reduction"
```

`flutter` is on PATH via `~/.bashrc`. Running any flutter command rewrites
`.flutter-plugins-dependencies` in a way that breaks a direct Gradle build —
harmless for tests, relevant if a build follows (see the `release-build` skill).

## Goldens are host-specific

Four files are tagged `@Tags(['golden'])` and excluded from CI with
`--exclude-tags golden`: `chat_search_capture_test`, `contact_profile_capture_test`,
`people_map_capture_test`, `profile_sections_capture_test`.

```bash
flutter test --tags golden
```

The reference PNGs live in `.codex/design-qa/`, not under `test/`. They were
recorded on this Windows machine; a Linux runner reproduces them within about 3%
of pixels, which is a real difference and not a real regression. **Some are stale
and red on a clean tree** — a red golden is not automatically caused by your
change. Failure images are written to `test/failures/`, which is gitignored.

When writing a capture test, use a static gradient rather than
`AuroraBackground`: the aurora drifts off a wall-clock Stopwatch, so its blobs
land at a different phase every run and the capture never matches itself.

## Two suite-wide gotchas

**`test/flutter_test_config.dart`** sets `UiActivity.debugDisableQuietTimer = true`
for the whole directory. `UiActivity` arms a four-second countdown on any touch
so decorative animations can park; `testWidgets` fails a test that finishes with
a pending timer, so without this every test that taps anything would have to know
about it. `ui_activity_test.dart` turns it back on for itself.

**`settleBackgroundStorage()`** from `test/support/hive_settle.dart` must be
awaited before closing Hive in any test that opens a box:

```dart
late Directory tempDir;

setUp(() async {
  tempDir = await Directory.systemTemp.createTemp('cubechat_archive_');
  Hive.init(tempDir.path);
});

tearDown(() async {
  await settleBackgroundStorage();
  await Hive.close();
  // Windows holds the Hive files briefly after close.
});
```

Controllers — `MessagingService` above all — open encrypted boxes from
constructors that cannot await them. Deleting the temp directory the moment the
body returns pulls storage out from under those opens, and the error lands in the
surrounding zone with no listener. `package:test` attributes it to whichever test
is running, usually one that already passed, so the symptom is
**"This test failed after it had already completed"** in an unrelated file, about
one run in two. Nothing in application code can catch it; the fix is not to race
it.

## Widget tests

Override Riverpod controllers by subclassing and passing the constructor
tear-off — `overrideWith` for a Notifier, `overrideWithValue` for a plain
provider:

```dart
class _FakeMessages extends MessagesController {
  @override
  Map<String, List<Message>> build() => { /* fixture */ };
}

ProviderScope(
  overrides: [
    chatsProvider.overrideWithValue([...]),
    messagesControllerProvider.overrideWith(_FakeMessages.new),
  ],
  child: ...,
)
```

Widgets need `AppLocalizations` in scope; copy the harness from
`chat_search_capture_test.dart`.

### A screen whose state comes from the identity cannot be pumped into place

`ChannelInfoScreen` claims its seat in `initState` — `ensureSelf` awaits
`identityProvider.future`, which mints an Ed25519 keypair through secure storage
and a file. That is real asynchronous work: a widget test's clock never performs
it, so the `setState` at the end never runs and the screen draws the member's
half however the roster is set up. Awaiting the provider from the test does not
fix it either; the screen's own call is still in flight when the test ends, and
resumes against a container that has been disposed.

Override the controller and hand the answer over instead — `_Roster` in
`channel_info_screen_test.dart` returns a roster from `build()` (without calling
`super.build()`, which would load Hive over it a frame later) and a synchronous
`ensureSelf`. What the screen is being asked is which half to draw, and that is
the part worth pinning.

### `pump()` draws nothing unless a frame is already scheduled

`tester.pump()` runs `handleBeginFrame`/`handleDrawFrame` **only** when
`hasScheduledFrame` — with nothing dirty it returns having done absolutely
nothing, silently and successfully. Anything hooked to the frame lifecycle
(`addPersistentFrameCallback`, a painter's repaint, a ticker) therefore does not
run, and the test fails on a wrong value rather than on a missing frame. Cost an
hour on `frame_stats_test.dart`, where two `pump()`s produced zero frames and the
per-frame counters read empty.

```dart
tester.binding.scheduleFrame();
await tester.pump();
```

### `fakeAsync` only drives what was built inside it

A controller built in `setUp` and then driven inside `fakeAsync` stalls at its
first `await`: a future created outside the fake zone completes on the *real*
microtask queue, which `flushMicrotasks` never runs, so the test sees the phase
it started in. Build the object inside the `fakeAsync` body. A single-
subscription `StreamController` it listens to must be recreated there too —
cancelling the old listener does not free the stream ("Stream has already been
listened to"). `call_controller_test.dart` does both.

Two related clocks, also worth keeping straight: `tester.pump(duration)` moves
the **test's** clock, and anything reading `DateTime.now()` — the warm-up filter
in `FrameStats`, every freshness window in the app — does not see it. Real time
needs `await tester.runAsync(() => Future.delayed(...))`.

### A phone-sized capture needs the view resized, not the surface

`tester.binding.setSurfaceSize(Size(390, 844))` shrinks what is drawn but
leaves `MediaQuery.sizeOf` at the 800x600 test default. Anything sized from
the screen width — the bubble's `0.75 * width` cap — then lays out for an
800-wide screen inside a 390-wide one and draws overflow stripes the phone
never shows. Cost a false "RenderFlex overflowed by 168 pixels" on the 1046
text-scale captures. Set the view instead:

```dart
tester.view.physicalSize = const Size(1170, 2532);
tester.view.devicePixelRatio = 3;
addTearDown(tester.view.reset);
```

A capture with tofu boxes for text also lies about widths: load `Inter` from
`assets/fonts/`, and `SpaceGrotesk`/`JetBrainsMono` from `.codex/fonts/`, with
`FontLoader` before judging any alignment.

## Analyze

```bash
flutter analyze
```

Strict mode is on: `strict-casts`, `strict-inference`, `strict-raw-types`, plus
`prefer_const_constructors`, `prefer_final_locals`, `avoid_print` and
`require_trailing_commas`.

The tree carries several hundred style infos, so CI gates on errors and warnings
only. **The severity separator differs by platform** — `error -` on Windows,
`error •` on the Linux runner. Grep for both or CI will catch warnings that are
invisible locally:

```bash
flutter analyze 2>&1 | grep -E "^[[:space:]]*(error|warning)[[:space:]]*[-•]"
```
