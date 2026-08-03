import 'dart:io';

import 'package:cubechat/core/widgets/identity_avatar.dart';
import 'package:cubechat/features/chat/presentation/widgets/media_picker_sheet.dart';
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
    // The settings are four collapsible groups now rather than a flat run of
    // cards, so the thing to check is that a group header is built — the
    // uppercase section labels this used to look for are gone with the layout
    // that needed them.
    expect(find.text(t.profileGroupConnection), findsOneWidget);
    expect(find.text(t.profileGroupApp), findsOneWidget);
  });

  testWidgets('a group opens to reveal its settings', (tester) async {
    // Closed by default is the whole point — thirteen cards became six rows —
    // so the rows inside must genuinely be absent until asked for, not merely
    // scrolled past.
    await pumpProfile(tester);
    final t = await AppLocalizations.delegate.load(const Locale('en'));

    expect(find.text(t.profileTransportMesh), findsNothing);

    await tester.tap(find.text(t.profileGroupConnection));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text(t.profileTransportMesh), findsOneWidget);
  });

  testWidgets('the header rests compact and opens when pulled', (tester) async {
    // The whole point of the rework: a photo filling the top of every visit is
    // the wrong default, so the cover starts as a circle and only opens when
    // asked. Measured through the content below it — if the header grows, the
    // settings move down with it.
    await pumpProfile(tester);
    final t = await AppLocalizations.delegate.load(const Locale('en'));

    final before = tester.getTopLeft(find.text(t.profileFingerprint)).dy;

    await tester.drag(
      find.byType(CustomScrollView),
      const Offset(0, 260),
      touchSlopY: 0,
    );
    await tester.pumpAndSettle();

    final after = tester.getTopLeft(find.text(t.profileFingerprint)).dy;
    expect(after, greaterThan(before),
        reason: 'pulling down past the top should open the cover');
  });

  testWidgets('nothing in the header overlaps once it is scrolled', (tester) async {
    // The first build let the header shrink while the avatar stayed pinned to
    // its top, the actions to its bottom and the name to a point between —
    // squeezing the box drove all three into each other. Scrolling must move
    // the header away, not compress it.
    await pumpProfile(tester);
    final t = await AppLocalizations.delegate.load(const Locale('en'));

    final actions = find.text(t.profileMyCard);
    final beforeTop = tester.getTopLeft(actions).dy;

    await tester.drag(
      find.byType(CustomScrollView),
      const Offset(0, -220),
      touchSlopY: 0,
    );
    await tester.pumpAndSettle();

    // Either scrolled off, or moved up by the full drag — never parked at the
    // top of the screen on top of the name.
    if (actions.evaluate().isNotEmpty) {
      final afterTop = tester.getTopLeft(actions).dy;
      expect(afterTop, lessThan(beforeTop - 100),
          reason: 'the header should travel with the scroll, not compress');
    }
  });

  testWidgets('the photo button opens the gallery directly', (tester) async {
    // "Nothing happens" is the report. A label rendering in the right place
    // proves only that it is drawn — this presses it and asserts the screen
    // behind it arrives, which is the part that was in doubt.
    await pumpProfile(tester);
    final t = await AppLocalizations.delegate.load(const Locale('en'));

    await tester.tap(find.text(t.avatarSet));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byType(MediaPickerSheet),
      findsOneWidget,
      reason: 'tapping the photo action must open the gallery immediately',
    );
  });

  testWidgets('the gallery opens above the tab shell', (tester) async {
    final rootNavigatorKey = GlobalKey<NavigatorState>();
    final branchNavigatorKey = GlobalKey<NavigatorState>();
    const shellNavigationKey = Key('shell-navigation');

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          navigatorKey: rootNavigatorKey,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Stack(
              children: [
                Navigator(
                  key: branchNavigatorKey,
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: ProfileScreen()),
                  ),
                ),
                const Align(
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(
                    key: shellNavigationKey,
                    height: 96,
                    width: double.infinity,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final t = await AppLocalizations.delegate.load(const Locale('en'));

    await tester.tap(find.text(t.avatarSet));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      rootNavigatorKey.currentState!.canPop(),
      isTrue,
      reason: 'the gallery route must cover the entire tab shell',
    );
    expect(
      branchNavigatorKey.currentState!.canPop(),
      isFalse,
      reason: 'the branch navigator must remain on the profile route',
    );
    expect(find.byType(MediaPickerSheet), findsOneWidget);
  });

  testWidgets('the avatar circle is not sitting on top of the actions',
      (tester) async {
    // The tap target is what broke before: the header squeezed, and the circle
    // ended up over the button. Geometry, not appearance — they must not
    // intersect.
    await pumpProfile(tester);
    final t = await AppLocalizations.delegate.load(const Locale('en'));

    final action = tester.getRect(find.text(t.avatarSet));
    final avatar = tester.getRect(find.byType(GestureDetector).first);
    expect(action.overlaps(avatar), isFalse,
        reason: 'the circle must not cover the button that opens the picker');
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
