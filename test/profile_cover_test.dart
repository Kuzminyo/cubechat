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

  testWidgets('the face sits in the middle of the header at rest',
      (tester) async {
    // The header used to be a list row: a small disc in the left corner with
    // the name beside it. The photo is the subject of this screen, so at rest
    // it is centred with the name under it — and "centred" is a number, which
    // a golden can only show and cannot check.
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpProfile(tester);

    final disc = find.byKey(const ValueKey('profile-cover-face'));
    expect(disc, findsOneWidget);
    final centre = tester.getCenter(disc);
    expect(centre.dx, closeTo(180, 1),
        reason: 'the disc is off the middle of a 360-point screen');
    expect(tester.getSize(disc).width, closeTo(92, 0.5));
  });

  testWidgets('pulling the list past the top opens it as well', (tester) async {
    // Two ways in, on purpose: the swipe up the face is the one that reads as
    // being about the picture, and the pull is what a thumb already at the top
    // of a list does without thinking. Neither costs the other anything — the
    // face claims only drags that start on it.
    await pumpProfile(tester);

    // The first section row is the first thing under the cover.
    final below = find.byIcon(Icons.alternate_email_rounded);
    final before = tester.getTopLeft(below).dy;
    await tester.drag(
      find.byType(CustomScrollView),
      const Offset(0, 260),
      // Default slop, not 0: the drag starts on a section row, and a
      // zero-slop drag on an InkWell never becomes a scroll in the test
      // binding (a finger does — checked against a plain InkWell ListView).
    );
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(below).dy, greaterThan(before));
  });

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
    // The screen changed from a ListView to a CustomScrollView; the rows must
    // still be built rather than silently dropped outside the sliver. The
    // settings are a list of sections now (see profile_sections_test), so the
    // check is the first section row and, scrolled to, the last one.
    await pumpProfile(tester);
    final t = await AppLocalizations.delegate.load(const Locale('en'));

    expect(find.text(t.cubeIdTitle), findsOneWidget);
    // Scrolled to rather than expected on screen: a sliver does not build what
    // is past the fold of a test viewport, and reaching it by scrolling proves
    // the row is in the sliver at all, which is what this test is about.
    await tester.scrollUntilVisible(
      find.text(t.sectionAbout),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text(t.sectionAbout), findsOneWidget);
  });

  testWidgets('the header rests compact and opens on a swipe up the face',
      (tester) async {
    // The whole point of the rework: a photo filling the top of every visit is
    // the wrong default, so the cover starts as a circle and only opens when
    // asked. Measured through the content below it — if the header grows, the
    // settings move down with it.
    //
    // The gesture is on the picture, not on the list. It used to be a pull on
    // the list, which put "see the photo" and "read the settings" on the same
    // axis pulling opposite ways.
    await pumpProfile(tester);

    final below = find.byIcon(Icons.alternate_email_rounded);
    final before = tester.getTopLeft(below).dy;

    await tester.drag(
      find.byKey(const ValueKey('profile-cover-face')),
      const Offset(0, -120),
      touchSlopY: 0,
    );
    await tester.pumpAndSettle();

    final after = tester.getTopLeft(below).dy;
    expect(after, greaterThan(before),
        reason: 'swiping up the picture should open the cover');

    // And back down again closes it, so the gesture is reversible where it
    // was made rather than only by scrolling away.
    await tester.drag(
      find.byKey(const ValueKey('profile-cover-face')),
      const Offset(0, 120),
      touchSlopY: 0,
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(below).dy, closeTo(before, 1));
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
      // Default slop — see the pull test above.
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
