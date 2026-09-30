@Tags(['golden'])
// Golden comparisons, so they are pinned to the machine that recorded them.
// Font rasterisation differs between platforms — these goldens were captured on
// Windows and a Linux runner reproduces them within about 3% of pixels, which
// is a real difference and not a real regression. Re-recording on CI would only
// move the failure to the developer's machine.
//
// Excluded from CI with `--exclude-tags golden`; run them locally, where the
// comparison means something, with `flutter test --tags golden`.
library;

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

  Future<GlobalKey> pumpCaptured(WidgetTester tester, Widget screen) async {
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
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.bgTop, AppColors.bgBottom],
                ),
              ),
              child: screen,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    return boundaryKey;
  }

  testWidgets('capture the profile as a list of sections', (tester) async {
    final boundaryKey = await pumpCaptured(tester, const ProfileScreen());
    await expectLater(
      find.byKey(boundaryKey),
      matchesGoldenFile('../.codex/design-qa/profile-sections-360x800.png'),
    );
  });

  testWidgets('capture the privacy & security section', (tester) async {
    final boundaryKey =
        await pumpCaptured(tester, const PrivacySectionScreen());
    await expectLater(
      find.byKey(boundaryKey),
      matchesGoldenFile(
        '../.codex/design-qa/profile-section-privacy-360x800.png',
      ),
    );
  });
}
