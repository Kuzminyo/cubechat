import 'package:cubechat/features/profile/presentation/sweeping_cat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Kubi sits still on the storage screen and sweeps only while clearing.
void main() {
  String shown(WidgetTester tester) {
    final image = tester.widget<Image>(find.byType(Image));
    return (image.image as ResizeImage).imageProvider is AssetImage
        ? ((image.image as ResizeImage).imageProvider as AssetImage).assetName
        : '';
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

  testWidgets('sits still until a clear starts, then sweeps', (tester) async {
    await pump(tester, false);
    expect(shown(tester), SweepingCat.sitting);
    await pump(tester, true);
    expect(shown(tester), SweepingCat.sweepingAsset);
  });

  testWidgets('with reduced motion it never sweeps', (tester) async {
    await pump(tester, true, reduced: true);
    expect(shown(tester), SweepingCat.sitting);
  });
}
