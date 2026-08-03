import 'dart:io';

import 'package:cubechat/app.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:cubechat/features/profile/data/ui_scale_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

/// How big the app draws itself.
///
/// The same build lands visibly larger on one phone than another: Android's
/// Display size and iOS's Larger Text both feed the text scaler, and neither is
/// visible from in here. Following the phone stays the default; the override is
/// for the phone that was tuned for something else — and it is clamped like any
/// other scale, because a setting that can break the layout is not a setting.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_scale_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the Hive files briefly after close.
    }
  });

  test('an unknown stored value falls back to following the phone', () {
    expect(UiScale.byName('enormous'), UiScale.system);
    expect(UiScale.byName(null), UiScale.system);
    expect(UiScale.byName('large'), UiScale.large);
    expect(UiScale.system.factor, isNull, reason: 'null means "use theirs"');
  });

  testWidgets('an override replaces the platform scale, and is clamped',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    // A phone already asking for text half again as large — the case the
    // override exists to answer.
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(const ProviderScope(child: CubechatApp()));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 400));

    final element = tester.element(find.byType(ChatsListScreen));
    final container = ProviderScope.containerOf(element);

    // Following the phone: 1.5 asked for, 1.3 allowed. The ceiling is where the
    // app's fixed-height capsules stop coping.
    expect(MediaQuery.textScalerOf(element).scale(10), 13);

    await container.read(uiScaleControllerProvider.notifier).select(
          UiScale.small,
        );
    await tester.pump();
    expect(
      MediaQuery.textScalerOf(tester.element(find.byType(ChatsListScreen)))
          .scale(10),
      9,
      reason: 'the choice overrides the phone rather than multiplying with it',
    );

    await container.read(uiScaleControllerProvider.notifier).select(
          UiScale.system,
        );
    await tester.pump();
    expect(
      MediaQuery.textScalerOf(tester.element(find.byType(ChatsListScreen)))
          .scale(10),
      13,
      reason: 'back to the phone, still clamped',
    );
  });
}
