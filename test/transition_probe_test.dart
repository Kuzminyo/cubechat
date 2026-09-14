import 'dart:ui';

import 'package:cubechat/core/util/transition_probe.dart';
import 'package:fake_async/fake_async.dart';
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

  test('nothing is measured while disarmed', () {
    fakeAsync((async) {
      final probe = TransitionProbe.instance;
      probe.noteResume();
      async.elapse(const Duration(seconds: 6));
      expect(probe.summary, isEmpty);
    });
  });
}
