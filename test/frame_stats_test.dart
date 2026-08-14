import 'package:cubechat/core/util/frame_stats.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

FrameTiming _frame({required int buildMs, required int rasterMs}) {
  // FrameTiming is built from raw timestamps, in microseconds.
  const start = 0;
  final buildEnd = buildMs * 1000;
  final rasterEnd = buildEnd + rasterMs * 1000;
  return FrameTiming(
    vsyncStart: start,
    buildStart: start,
    buildFinish: buildEnd,
    rasterStart: buildEnd,
    rasterFinish: rasterEnd,
    rasterFinishWallTime: rasterEnd,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    FrameStats.instance
      ..stop()
      ..reset();
  });

  test('the frames spent arriving are not counted', () async {
    FrameStats.instance
      ..reset()
      ..start();

    // The route transition: expensive, brief, and nothing to do with what the
    // panel is being read for.
    FrameStats.instance.ingestForTest([_frame(buildMs: 20, rasterMs: 40)]);
    expect(FrameStats.instance.avgRasterMs, 0,
        reason: 'nothing collected during the warm-up');

    await Future<void>.delayed(const Duration(milliseconds: 800));
    FrameStats.instance.ingestForTest([_frame(buildMs: 1, rasterMs: 2)]);

    expect(FrameStats.instance.avgRasterMs, closeTo(2, 0.5));
    expect(FrameStats.instance.avgBuildMs, closeTo(1, 0.5));
  });

  test('stopping detaches the per-frame callback', () async {
    FrameStats.instance
      ..reset()
      ..start();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    FrameStats.instance.ingestForTest([_frame(buildMs: 1, rasterMs: 2)]);
    expect(FrameStats.instance.avgRasterMs, greaterThan(0));

    FrameStats.instance
      ..stop()
      ..reset();
    // Stopped: the engine would no longer be calling us at all, which is the
    // point — nothing accumulates behind the panel's back.
    if (FrameStats.instance.isRunning) {
      FrameStats.instance.ingestForTest([_frame(buildMs: 9, rasterMs: 9)]);
    }

    // A screen nobody is looking at costs nothing per frame.
    expect(FrameStats.instance.avgRasterMs, 0);
  });
}
