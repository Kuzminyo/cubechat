import 'package:cubechat/core/theme/colors.dart';
import 'package:cubechat/core/theme/theme_controller.dart';
import 'package:cubechat/core/widgets/cube_logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The logo follows the palette, except that Emerald keeps the mark it has
/// always had.
///
/// The second half is the one that broke: the faces were first derived from
/// every palette's brand colours, Emerald included, which turned the in-app
/// cube mint while the home-screen icon stayed lime — and would have changed
/// the default icon on the next run of tool/export_logo.dart.
void main() {
  CubeLogoPainter painterFor(AppPalette p) => CubeLogoPainter(
        primary: p.brandPrimary,
        secondary: p.brandSecondary,
      );

  test('Emerald paints the original hand-picked faces', () {
    final faces = CubeFaces.of(
      AppPalette.emerald.brandPrimary,
      AppPalette.emerald.brandSecondary,
    );
    expect(faces, same(CubeFaces.classic));
    expect(faces.topDark, const Color(0xFFA3E635));
    expect(faces.leftDark, const Color(0xFF2D7211));
  });

  test('every other palette paints its own hue', () {
    for (final p in AppPalette.all) {
      if (p.id == AppPalette.emerald.id) continue;
      final faces = CubeFaces.of(p.brandPrimary, p.brandSecondary);
      expect(faces.topDark, isNot(CubeFaces.classic.topDark), reason: p.id);
      if (p.id == AppPalette.slate.id) continue; // grey has no hue to keep
      final want = HSLColor.fromColor(p.brandPrimary).hue;
      final got = HSLColor.fromColor(faces.rightDark).hue;
      expect((want - got).abs(), lessThan(1), reason: p.id);
    }
  });

  test('the face shading keeps its order: top lightest, left darkest', () {
    for (final p in AppPalette.all) {
      final f = CubeFaces.of(p.brandPrimary, p.brandSecondary);
      double l(Color c) => HSLColor.fromColor(c).lightness;
      expect(l(f.topDark), greaterThan(l(f.rightDark)), reason: p.id);
      expect(l(f.rightDark), greaterThan(l(f.leftDark)), reason: p.id);
    }
  });

  test('the painter repaints when the palette changes, and only then', () {
    expect(
      painterFor(AppPalette.fuchsia)
          .shouldRepaint(painterFor(AppPalette.emerald)),
      isTrue,
    );
    expect(
      painterFor(AppPalette.fuchsia)
          .shouldRepaint(painterFor(AppPalette.fuchsia)),
      isFalse,
    );
  });

  testWidgets('CubeLogo picks up the palette in force when it is built',
      (tester) async {
    final before = (AppColors.brandPrimary, AppColors.brandSecondary);
    addTearDown(() {
      AppColors.brandPrimary = before.$1;
      AppColors.brandSecondary = before.$2;
    });
    for (final p in [AppPalette.rose, AppPalette.emerald]) {
      // What ThemeController._apply writes for the two colours the logo reads.
      AppColors.brandPrimary = p.brandPrimary;
      AppColors.brandSecondary = p.brandSecondary;
      await tester.pumpWidget(const Center(child: CubeLogo(size: 40)));
      // The same const instance comes back on the second pass; in the app
      // ThemeController._rebuildEverything marks it dirty, as this does.
      tester.element(find.byType(CubeLogo)).markNeedsBuild();
      await tester.pump();
      final paint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(CubeLogo),
          matching: find.byType(CustomPaint),
        ),
      );
      final painter = paint.painter! as CubeLogoPainter;
      expect(painter.primary, p.brandPrimary, reason: p.id);
    }
  });
}
