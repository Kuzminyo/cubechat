import 'package:cubechat/core/theme/colors.dart';
import 'package:cubechat/features/profile/presentation/profile_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

/// Design-QA capture of the regrouped profile.
///
/// Static gradient rather than AuroraBackground: that one drifts off a
/// wall-clock Stopwatch, so its blobs land at a different phase every run and
/// the capture never matches itself.
void main() {
  late Directory tempDir;

  // The screen reads real settings on build, so it needs somewhere to read
  // them from — see channel_navigation_test for the same setup.
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_profile_qa_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('capture profile settings groups', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boundaryKey = GlobalKey();

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('uk'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark(useMaterial3: true),
          home: RepaintBoundary(
            key: boundaryKey,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.bgTop, AppColors.bgBottom],
                ),
              ),
              child: ProfileScreen(),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    // Closed: the whole screen should fit without scrolling.
    await expectLater(
      find.byKey(boundaryKey),
      matchesGoldenFile('../.codex/design-qa/profile-groups-closed-360x800.png'),
    );

    // Open the first group — the point of the redesign is that its rows appear
    // inside the same pane rather than as more slabs.
    await tester.tap(find.byIcon(Icons.podcasts_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await expectLater(
      find.byKey(boundaryKey),
      matchesGoldenFile('../.codex/design-qa/profile-groups-open-360x800.png'),
    );
  });
}
