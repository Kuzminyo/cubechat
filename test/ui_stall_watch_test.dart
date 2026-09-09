import 'package:cubechat/core/util/debug_log.dart';
import 'package:cubechat/core/util/ui_stall_watch.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The instrument for the failure the frame meter cannot see.
///
/// A blocked UI thread produces no frames, so it produces no timings, so
/// `FrameStats` reports nothing at all about the worst pauses there are. These
/// pin the two properties that make this watch usable rather than noisy: it
/// notices a loop that was held, and it stays quiet about a phone that was
/// simply in a pocket.
///
/// Plain `test`, not `testWidgets`, and deliberately. A widget test runs inside
/// `FakeAsync`, where a timer only fires when the test advances the clock — so
/// the very thing under test, a timer noticing real elapsed time, cannot
/// happen there at all. These have to spend the wall-clock second.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Lines reach the buffer through the debugPrint hook, not by being appended,
  // so without this the log stays empty and every assertion here passes for
  // the wrong reason.
  setUp(() {
    DebugLog.install();
    DebugLog.instance.clear();
  });
  tearDown(() {
    UiStallWatch.instance.stop();
    DebugLog.instance.clear();
  });

  Iterable<String> stalls() => DebugLog.instance.entries
      .map((e) => e.line)
      .where((l) => l.contains('STALL'));

  /// Hold the event loop the way a synchronous platform call or a long build
  /// does: nothing else runs, the watch's own timer included.
  void block(Duration held) {
    final until = DateTime.now().add(held);
    while (DateTime.now().isBefore(until)) {
      // Busy on purpose. An await here would hand the loop back and there
      // would be no stall left to detect.
    }
  }

  test('a held event loop is reported, with how long it was held', () async {
    UiStallWatch.instance.install();
    block(const Duration(milliseconds: 900));
    // Let the late timer fire now that the loop is free again.
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(stalls(), isNotEmpty,
        reason: 'a loop held for 900 ms is exactly what this exists to catch');
    expect(stalls().first, contains('UI thread did not answer'));
  });

  test('a spell in the background is not reported as a stall', () async {
    UiStallWatch.instance.install();
    // The platform throttles timers for an app nobody is looking at, so the
    // tick spanning a return from the background is late for a reason that is
    // not a bug. A meter that shouts every time the phone leaves a pocket is
    // one people stop reading.
    UiStallWatch.instance.didChangeAppLifecycleState(AppLifecycleState.paused);
    block(const Duration(milliseconds: 900));
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(stalls(), isEmpty);
  });

  test('the tick that spans a resume is not blamed for the background',
      () async {
    UiStallWatch.instance.install();
    UiStallWatch.instance.didChangeAppLifecycleState(AppLifecycleState.paused);
    block(const Duration(milliseconds: 900));
    // Coming back restarts the clock rather than reporting the wait.
    UiStallWatch.instance.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(stalls(), isEmpty);
  });
}
