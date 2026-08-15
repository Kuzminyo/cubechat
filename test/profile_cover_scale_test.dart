import 'dart:io';

import 'package:cubechat/features/profile/presentation/profile_screen.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

/// The open profile cover, on a phone whose text is bigger than ours.
///
/// The name and the discoverability line under it are positioned from the
/// bottom of the header, just above the three action pills. That offset used to
/// be a constant measured against the stock font size, so a phone set to larger
/// text — an iPhone in particular, where the system default already runs bigger
/// — drew the name straight down onto the buttons. The invariant is simply that
/// it cannot: whatever the scale, the block ends above the row.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_cover_');
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

  for (final scale in [1.0, 1.15, 1.3]) {
    testWidgets('the name clears the action pills at scale $scale',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData.dark(useMaterial3: true),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                // An iPhone's status bar, so the compact header is sized the
                // way it is on the device this was reported from.
                padding: const EdgeInsets.only(top: 47),
              ),
              child: child!,
            ),
            home: ProfileScreen(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      // Pull past the top: that is what opens the photo, and open is the state
      // where the name and the buttons share a header.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 220));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final photoAction = find.byIcon(Icons.add_a_photo_rounded);
      expect(photoAction, findsOneWidget);
      final status = find.text('Anyone in range can find you');
      expect(status, findsOneWidget);

      expect(
        tester.getRect(status).bottom,
        lessThanOrEqualTo(tester.getRect(photoAction).top),
        reason: 'the discoverability line must end above the action row',
      );
    });
  }
}
