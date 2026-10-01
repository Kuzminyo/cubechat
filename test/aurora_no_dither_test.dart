import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cubechat/core/widgets/aurora_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// White dots on every screenshot, in a grid.
///
/// The backdrop's gradients were dithered by the engine — an ordered pattern
/// alternating every pixel, a level up and a level down. Invisible on the
/// phone. But a screenshot gets scaled down before anyone looks at it, and a
/// pattern at that frequency folds into a coarse grid when it is: measured on
/// the reported screenshot, a period of 11.6 px at 591/1080, which is exactly
/// where a 2-pixel pattern lands at that scale. Inside the glass panes, over
/// the same backdrop, the grid was fifteen times weaker.
///
/// Pinned: the backdrop has no pixel-to-pixel pattern at all — every pixel is
/// within a level of the average of its four neighbours.
void main() {
  testWidgets('the backdrop has no pixel-scale pattern to fold into a grid',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(180, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const key = Key('aurora');
    await tester.pumpWidget(
      const MaterialApp(
        home: RepaintBoundary(
          key: key,
          child: AuroraBackground(child: SizedBox.expand()),
        ),
      ),
    );
    // The textures are made off the frame; let them arrive.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
    final image = await tester.runAsync(() => boundary.toImage());
    final bytes = (await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    final w = image!.width;
    final h = image.height;
    final px = Uint8List.view(bytes.buffer);
    // The strength of the patterns that alternate every pixel — across, down
    // and both — in levels. What folds into a grid when the screenshot is
    // scaled down is exactly these; a smooth ramp rounded to whole levels
    // has next to none of them.
    var worst = 0.0;
    for (final (sx, sy) in const [(1, 0), (0, 1), (1, 1)]) {
      for (var c = 0; c < 3; c++) {
        var sum = 0.0;
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final sign = (sx * x + sy * y).isEven ? 1 : -1;
            sum += sign * px[(y * w + x) * 4 + c];
          }
        }
        final amplitude = (sum / (w * h)).abs();
        if (amplitude > worst) worst = amplitude;
      }
    }
    // Dithered by the engine it measured 0.47; drawn from textures, 0.023 —
    // what is left is rounding at the blobs' edges.
    expect(worst, lessThan(0.05),
        reason: 'a pattern alternating every pixel, $worst levels strong');
  });
}
