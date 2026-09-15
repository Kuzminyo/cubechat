import 'dart:ui';

import 'package:cubechat/core/util/transition_probe.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

FrameTiming _frame(int number, {required int buildMs, required int rasterMs}) {
  final start = number * 8333;
  final buildEnd = start + buildMs * 1000;
  final rasterEnd = buildEnd + rasterMs * 1000;
  return FrameTiming(
    vsyncStart: start,
    buildStart: start,
    buildFinish: buildEnd,
    rasterStart: buildEnd,
    rasterFinish: rasterEnd,
    rasterFinishWallTime: rasterEnd,
    frameNumber: number,
  );
}

/// The Diagnostics transition meter: one window of frames per transition,
/// counted by the engine's frame numbers, filed under a scenario.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TransitionProbe.instance
      ..arm(false)
      ..resetSummary();
  });

  test('percentiles are nearest-rank, in milliseconds', () {
    final samples = [for (var i = 1; i <= 100; i++) i * 1000];
    expect(TransitionReport.percentileMs(samples, 0.95), 95);
    expect(TransitionReport.percentileMs(samples, 0.99), 99);
    expect(TransitionReport.percentileMs(samples, 1), 100);
    expect(TransitionReport.percentileMs(const [], 0.95), 0);
  });

  test('a window counts its frames against both budgets and files a scenario',
      () {
    fakeAsync((async) {
      final probe = TransitionProbe.instance..arm(true);
      probe.noteResume();
      // Timings arrive before the window closes, as a release batch would.
      probe.ingestForTest([
        _frame(1, buildMs: 2, rasterMs: 3),
        _frame(2, buildMs: 12, rasterMs: 3),
        _frame(3, buildMs: 2, rasterMs: 21),
      ]);
      async.elapse(const Duration(seconds: 2));

      final rows = probe.summary;
      expect(rows, hasLength(1));
      expect(rows.single.name, startsWith('resume app'));
      expect(rows.single.runs, 1);
      expect(rows.single.over8PerRun, 2, reason: '12 ms build, 21 ms raster');
      expect(rows.single.over16PerRun, 1, reason: 'only the 21 ms raster');
      expect(rows.single.rasterP99, 21);
    });
  });

  test('a scripted run says where in the window each slow frame fell', () {
    fakeAsync((async) {
      final probe = TransitionProbe.instance
        ..scripted = true
        ..arm(true);
      probe.noteResume();
      // Frames 8.3 ms apart, the window starting after the frame already on
      // the go: a slow build on its first frame, and a slow raster fourteen
      // frames later, 108 ms in.
      probe.ingestForTest([
        _frame(2, buildMs: 19, rasterMs: 2),
        for (var n = 3; n < 15; n++) _frame(n, buildMs: 1, rasterMs: 2),
        _frame(15, buildMs: 1, rasterMs: 12),
      ]);
      async.elapse(const Duration(seconds: 2));
      probe.scripted = false;

      final row = probe.summary.single;
      expect(row.slowByTenthPerRun, [1, 1, 0, 0, 0, 0]);
      expect(row.line, contains('slow per 100 ms 1.0/1.0/0.0/0.0/0.0/0.0'));
    });
  });

  test('a slow frame reads as when, and which thread', () {
    expect(
      const SlowFrame(atMs: 120, buildMs: 1.2, rasterMs: 13.4).toString(),
      '+120:r13',
    );
    expect(
      const SlowFrame(atMs: 0, buildMs: 21.6, rasterMs: 2).toString(),
      '+0:b22',
    );
  });

  test('a push made while a frame is building counts that frame', () {
    // The router's push: didPush runs inside the build of frame 40, and frame
    // 40 is the one that builds the new screen.
    expect(
      TransitionProbe.windowStart(40, SchedulerPhase.persistentCallbacks),
      39,
    );
    expect(
      TransitionProbe.windowStart(40, SchedulerPhase.transientCallbacks),
      39,
    );
    // A tap between frames: the next frame is the first.
    expect(TransitionProbe.windowStart(40, SchedulerPhase.idle), 40);
    expect(TransitionProbe.windowStart(40, SchedulerPhase.postFrameCallbacks), 40);
  });

  test('nothing is measured while disarmed', () {
    fakeAsync((async) {
      final probe = TransitionProbe.instance;
      probe.noteResume();
      async.elapse(const Duration(seconds: 6));
      expect(probe.summary, isEmpty);
    });
  });
}
