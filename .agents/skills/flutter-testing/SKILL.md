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
