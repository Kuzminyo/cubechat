import 'package:cubechat/core/util/frame_stats.dart';
import 'package:flutter/material.dart';
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

  testWidgets('a slow frame names what that frame rebuilt, not the second '
      'around it', (tester) async {
    FrameStats.instance
      ..reset()
      ..start();
    await tester.pumpWidget(const SizedBox.shrink());

    // The warm-up, played out rather than skipped. Frames are drawn and their
    // timings arrive, and those timings are discarded — which is the whole
    // point of the warm-up and was also the bug: discarding used to return
    // without taking the frame's entry off the queue, so everything afterwards
    // was answered about a frame six or seven back. A shipped log read
    // `nothing counted rebuilt` on every slow frame in it, which is impossible
    // during a route transition and was a broken meter, not a finding.
    for (var i = 0; i < 3; i++) {
      FrameStats.countBuild('during-the-warm-up');
      tester.binding.scheduleFrame();
      await tester.pump();
      FrameStats.instance.ingestForTest([_frame(buildMs: 1, rasterMs: 1)]);
    }

    // Real time, not pumped time: the warm-up filter reads the wall clock, and
    // `pump` moves the test's clock without moving that one.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 800)),
    );

    // Frame one rebuilds something. `pump` only draws when a frame is already
    // scheduled — with nothing dirty it returns having done nothing at all —
    // so the frame has to be asked for explicitly.
    FrameStats.countBuild('chats');
    tester.binding.scheduleFrame();
    await tester.pump();
    // Frame two rebuilds something else, and is the slow one.
    FrameStats.countBuild('chat');
    tester.binding.scheduleFrame();
    await tester.pump();

    // Two timings, in the order the frames were drawn. The first is cheap and
    // reports nothing; the second is what lands in the log.
    FrameStats.instance.ingestForTest([_frame(buildMs: 1, rasterMs: 1)]);
    FrameStats.instance.ingestForTest([_frame(buildMs: 25, rasterMs: 2)]);

    expect(FrameStats.instance.lastSlowFrameWho, 'chat x1');
    expect(
      FrameStats.instance.lastSlowFrameWho,
      isNot(contains('chats')),
      reason: 'the cheap frame before it must not be blamed for this one',
    );
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
