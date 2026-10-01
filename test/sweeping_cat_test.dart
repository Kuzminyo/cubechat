import 'package:cubechat/features/profile/presentation/sweeping_cat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Kubi sits still on the storage screen, gets up and sweeps when a clear
/// starts, and sits back down only at the end of his round.
void main() {
  String shown(WidgetTester tester) {
    final image = tester.widget<Image>(find.byType(Image));
    final resized = image.image as ResizeImage;
    return (resized.imageProvider as AssetImage).assetName;
  }

  Future<void> pump(WidgetTester tester, bool sweeping,
      {bool reduced = false}) async {
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Center(child: SweepingCat(sweeping: sweeping)),
      ),
    );
  }

  testWidgets('sits still until a clear starts, then plays his routine',
      (tester) async {
    await pump(tester, false);
    expect(shown(tester), SweepingCat.sitting);
    await pump(tester, true);
    expect(shown(tester), SweepingCat.sweepingAsset);
  });

  testWidgets('a quick clear still gets a whole round, then he sits',
      (tester) async {
    await pump(tester, false);
    await pump(tester, true);
    await tester.pump(const Duration(milliseconds: 200));
    // The clear is over in a fifth of a second...
    await pump(tester, false);
    expect(shown(tester), SweepingCat.sweepingAsset);
    // ...and he finishes the round he started rather than stopping mid-stroke.
    await tester.pump(const Duration(seconds: 5));
    expect(shown(tester), SweepingCat.sweepingAsset);
    await tester.pump(SweepingCat.routine);
    expect(shown(tester), SweepingCat.sitting);
  });

  testWidgets('with reduced motion he never gets up', (tester) async {
    await pump(tester, false, reduced: true);
    await pump(tester, true, reduced: true);
    expect(shown(tester), SweepingCat.sitting);
  });
}
