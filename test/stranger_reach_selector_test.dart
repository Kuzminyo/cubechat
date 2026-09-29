import 'dart:io';

import 'package:cubechat/features/cube_id/presentation/stranger_reach_selector.dart';
import 'package:cubechat/features/profile/data/privacy_settings_controller.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

class _FakePrivacy extends PrivacySettingsController {
  final chosen = <StrangerReach>[];

  @override
  PrivacySettings build() =>
      PrivacySettings.initial.copyWith(strangerReach: StrangerReach.request);

  @override
  Future<void> setStrangerReach(StrangerReach value) async {
    chosen.add(value);
    state = state.copyWith(strangerReach: value);
  }
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cubechat_reach_ui_');
    Hive.init(dir.path);
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the Hive files briefly after close.
    }
  });

  testWidgets('shows the three choices on one line each and saves a tap',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final fake = _FakePrivacy();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [privacySettingsProvider.overrideWith(() => fake)],
        child: const MaterialApp(
          locale: Locale('uk'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Padding(
              padding: EdgeInsets.all(20),
              child: StrangerReachSelector(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Хто може писати мені з інтернету'), findsOneWidget);
    final request = find.text('Через запит');
    expect(request, findsOneWidget);
    // One line: "Через запит" wrapped onto two on a phone (screenshot,
    // 2026-09-29).
    final line = tester.getSize(request).height;
    final single = tester.getSize(find.text('Усі')).height;
    expect(line, single);

    await tester.tap(find.text('Ніхто'));
    await tester.pump();
    expect(fake.chosen, [StrangerReach.none]);
  });
}
