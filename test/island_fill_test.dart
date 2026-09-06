// The island fill must deepen evenly, not open with a pale band.
//
// This bug came back four times, and every time the search went to the edges —
// the border, the blur's rim, two drop shadows — because a gradient stop does
// not look like an edge in the code. It was `glass(0.07)` (white) as the first
// colour of the fill, reaching `pane(0.48)` only a third of the way down: a
// pale band across the top of every island with a soft boundary where it
// settled, and on a bright wallpaper the most visible thing on the screen.
//
// What is measured here is *evenness*, not brightness. The fill is meant to be
// lighter at the top — it deepens downward, which is what stops an island
// reading as a flat rectangle — so "the top is lighter" is the design and
// cannot be the test. What made it a band is that nearly all of the change
// happened in the first third. So: walk the island in tenths, and require that
// no tenth carries a large share of the whole top-to-bottom change.
//
// The legacy fill is kept below and asserted to FAIL the same metric. A
// regression test that has never seen the regression is a guess, and this one
// has four builds' worth of reasons not to be trusted on its word.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cubechat/core/theme/colors.dart';
import 'package:cubechat/features/chat/presentation/widgets/chat_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const double _width = 300;
const double _height = 120;

/// The fill exactly as it shipped through build 967, kept only so the metric
/// below can be shown to catch it.
class _LegacyIsland extends StatelessWidget {
  const _LegacyIsland();

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(26);
    return ClipRRect(
      borderRadius: radius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppColors.glass(0.07),
              AppColors.pane(0.48),
              AppColors.pane(0.60),
            ],
            stops: const [0, 0.35, 1],
          ),
          borderRadius: radius,
          border: Border.all(color: AppColors.glass(0.07)),
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Mean luminance of one horizontal slice, sampled across the middle half of
/// the width so the rounded corners and the border never enter the average.
double _sliceLuma(ByteData pixels, int top, int bottom) {
  const w = _width ~/ 1;
  var total = 0.0;
  var count = 0;
  for (var y = top; y < bottom; y++) {
    for (var x = w ~/ 4; x < w - w ~/ 4; x++) {
      final o = (y * w + x) * 4;
      total += 0.2126 * pixels.getUint8(o) +
          0.7152 * pixels.getUint8(o + 1) +
          0.0722 * pixels.getUint8(o + 2);
      count++;
    }
  }
  return total / count;
}

/// The largest share of the whole top-to-bottom luminance change carried by
/// any single tenth of the island's height. An even ramp gives about 0.1;
/// a band gives whatever fraction of the change its edge carries.
Future<double> _bandSeverity(WidgetTester tester, Widget island) async {
  tester.view.physicalSize = const Size(_width, _height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(_width, _height)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [
              // Flat and bright: any variation in the capture is the fill's
              // doing and nothing else's.
              const Positioned.fill(
                child: ColoredBox(color: Color(0xFF7FE9B4)),
              ),
              Positioned.fill(child: island),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  late ByteData pixels;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  });

  // Tenths, skipping the outermost rows: the border is meant to be a light
  // hairline and is not what anybody means by a band.
  const first = 4;
  const last = _height ~/ 1 - 4;
  const span = last - first;
  final marks = <double>[
    for (var i = 0; i <= 10; i++)
      _sliceLuma(
        pixels,
        first + (span * i ~/ 10) - (i == 10 ? 3 : 0),
        first + (span * i ~/ 10) + (i == 10 ? 0 : 3),
      ),
  ];
  final total = (marks.first - marks.last).abs();
  if (total < 1) return 0; // A perfectly flat fill has no band by definition.
  var worst = 0.0;
  for (var i = 0; i < 10; i++) {
    final step = (marks[i] - marks[i + 1]).abs() / total;
    if (step > worst) worst = step;
  }
  return worst;
}

/// An even ramp puts about a tenth of its change in each tenth. Twice that is
/// generous room for the blur's own falloff and still nowhere near a band.
const double _evenEnough = 0.22;

void main() {
  testWidgets('the chat island fill deepens evenly', (tester) async {
    final severity = await _bandSeverity(
      tester,
      const MessageIslandGlass(child: SizedBox.expand()),
    );
    expect(
      severity,
      lessThan(_evenEnough),
      reason: 'MessageIslandGlass puts ${(severity * 100).round()}% of its '
          'whole vertical change into one tenth of its height. That '
          'concentration is the pale band across the top of the islands.',
    );
  });

  // [FloatingGlass] — the chat-list tiles and the other floating panes — keeps
  // the old fill on purpose. It was changed alongside the chat islands for
  // consistency and taken straight back out: the band is a complaint about the
  // chat, the tiles were not what anybody asked about, and a surface nobody
  // objected to does not get changed to match an argument about another one.
  // So there is no evenness test for it, and there should not be one.

  testWidgets('the metric catches the fill that shipped through 967',
      (tester) async {
    final severity = await _bandSeverity(tester, const _LegacyIsland());
    expect(
      severity,
      greaterThan(_evenEnough),
      reason: 'The legacy fill drew a band and this metric must see it, '
          'or the two tests above are worth nothing.',
    );
  });
}
