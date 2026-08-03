import 'dart:io';

import 'package:cubechat/core/theme/colors.dart';
import 'package:cubechat/core/theme/theme_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// A palette has to reach the interface, not just the accents on it.
///
/// The glass in this app is white at a low opacity over the aurora, and while
/// that white was literally `Colors.white` every theme produced the same grey
/// app with differently coloured buttons. What is pinned here is that choosing
/// a palette moves the white too — and that Graphite, the deliberately
/// colourless one, is left alone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_palette_test_');
    Hive.init(tempDir.path);
    container = ProviderContainer();
  });

  tearDown(() async {
    await settleBackgroundStorage();
    container.dispose();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the Hive files briefly after close.
    }
  });

  test('an unknown id falls back to the stock look', () {
    expect(AppPalette.byId('a-palette-from-a-later-build').id, 'emerald');
    expect(AppPalette.byId(null).id, 'emerald');
  });

  test('choosing Fuchsia tints the glass and the ink, not just the brand',
      () async {
    await container
        .read(themeControllerProvider.notifier)
        .select(AppPalette.fuchsia);

    expect(AppColors.brandPrimary, AppPalette.fuchsia.brandPrimary);
    expect(AppColors.bgDeep, AppPalette.fuchsia.bgDeep);
    expect(AppColors.glassBase, isNot(Colors.white),
        reason: 'a pane of glass has to carry the palette');
    expect(AppColors.glassBase.b, lessThan(AppColors.glassBase.r),
        reason: 'pink glass, so less blue in it than red');
    expect(AppColors.glassFill, AppColors.glass(0.08));
    expect(AppColors.textOnGlass, AppColors.ink(0.95));
    // Ink is tinted too, but far less: a label is there to be read.
    expect(
      Colors.white.b - AppColors.inkBase.b,
      lessThan(Colors.white.b - AppColors.glassBase.b),
    );
  });

  test('Graphite keeps its glass neutral', () async {
    await container
        .read(themeControllerProvider.notifier)
        .select(AppPalette.fuchsia);
    await container
        .read(themeControllerProvider.notifier)
        .select(AppPalette.slate);

    expect(AppColors.glassBase, Colors.white);
    expect(AppColors.inkBase, Colors.white);
  });

  test('every palette is reachable and distinct', () {
    final ids = AppPalette.all.map((p) => p.id).toList();
    expect(ids.toSet(), hasLength(ids.length));
    for (final id in ids) {
      expect(AppPalette.byId(id).id, id);
    }
  });
}
