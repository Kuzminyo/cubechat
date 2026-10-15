import 'package:cubechat/core/theme/glass_tier.dart';
import 'package:cubechat/core/util/frame_stats.dart';
import 'package:flutter_test/flutter_test.dart';

/// Auto glass never decided anything.
///
/// It read its numbers from [FrameStats], which only collects while the
/// Diagnostics screen is open. Everywhere else it counted no frames, so the
/// "too few frames to judge" branch rescheduled the measurement forever and
/// the glass stayed full — on a Mali phone drawing at raster avg 25 / p90
/// 38.7 ms, which is 30 fps, exactly what it was bought to prevent.
void main() {
  test('the window measures frames by itself, with Diagnostics closed', () {
    expect(FrameStats.instance.isRunning, isFalse);
    final window = RasterWindow();
    for (var i = 0; i < 400; i++) {
      window.add(Duration(microseconds: i < 350 ? 25000 : 39000));
    }
    expect(window.count, 400);
    expect(window.p90Ms, closeTo(39, 0.01));
    expect(window.worstMs, closeTo(39, 0.01));
  });

  test("the friend's phone gets light glass; a healthy one keeps full", () {
    expect(
      GlassTierController.verdictFor(p90Ms: 38.7, worstMs: 85),
      GlassTier.light,
    );
    expect(
      GlassTierController.verdictFor(p90Ms: 5.6, worstMs: 21),
      GlassTier.full,
    );
    // One stop long enough to feel is enough on its own.
    expect(
      GlassTierController.verdictFor(p90Ms: 4.5, worstMs: 93),
      GlassTier.light,
    );
  });

  test('a phone fine at rest but slow on every screen change loses the blur',
      () {
    // Still screens inside 60 Hz, slides at 20 ms on a 60 Hz panel: passed
    // the old verdict, stuttered on every chat (2026-10-15).
    expect(
      GlassTierController.verdictFor(
        p90Ms: 12,
        worstMs: 30,
        slideP90Ms: 22,
        budgetMs: 1000 / 60,
      ),
      GlassTier.light,
    );
    // The S24+ on 1163: slides at ~11 ms on a 120 Hz panel. Keeps it.
    expect(
      GlassTierController.verdictFor(
        p90Ms: 4.8,
        worstMs: 36,
        slideP90Ms: 11,
        budgetMs: 1000 / 120,
      ),
      GlassTier.full,
    );
    // The same 11 ms on a 90 Hz panel is inside its 15.3 too.
    expect(
      GlassTierController.verdictFor(
        p90Ms: 6,
        worstMs: 30,
        slideP90Ms: 11,
        budgetMs: 1000 / 90,
      ),
      GlassTier.full,
    );
  });
}
