import 'dart:io';

import 'package:cubechat/core/widgets/identity_avatar.dart';
import 'package:cubechat/features/profile/presentation/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cubechat/l10n/app_localizations.dart';

import 'support/hive_settle.dart';

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
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> pumpProfile(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: ProfileScreen()),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the cover offers the three actions it advertises',
      (tester) async {
    await pumpProfile(tester);
    final t = await AppLocalizations.delegate.load(const Locale('en'));

    // Every button on the cover has to go somewhere; the whole reason there are
    // three and not five is that a button opening nothing reads as unfinished.
    expect(find.text(t.avatarSet), findsOneWidget);
    expect(find.text(t.profileEditName), findsOneWidget);
    expect(find.text(t.profileMyCard), findsOneWidget);
  });

  testWidgets('the settings below the cover survived the move to slivers',
      (tester) async {
    // The screen changed from a ListView to a CustomScrollView; the cards must
    // still be built rather than silently dropped outside the sliver.
    await pumpProfile(tester);
    final t = await AppLocalizations.delegate.load(const Locale('en'));

    expect(find.text(t.profileFingerprint), findsOneWidget);
    expect(find.text(t.profileLanguage.toUpperCase()), findsWidgets);
  });

  group('IdentityAvatar.paletteFor', () {
    test('is stable for a seed', () {
      // The cover paints the whole header with it while the circle paints a
      // 44 px disc; if the two disagreed the header would flicker to another
      // colour on every rebuild.
      expect(
        IdentityAvatar.paletteFor('abc'),
        equals(IdentityAvatar.paletteFor('abc')),
      );
    });

    test('always returns a usable pair of colours', () {
      for (final seed in ['', 'a', 'зеленый', '0" * 64']) {
        expect(IdentityAvatar.paletteFor(seed).length, 2);
      }
    });
  });
}
