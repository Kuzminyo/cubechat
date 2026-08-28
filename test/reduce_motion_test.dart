import 'package:cubechat/core/routing/page_transitions.dart';
import 'package:cubechat/core/util/motion.dart';
import 'package:cubechat/core/widgets/appear_animation.dart';
import 'package:cubechat/core/widgets/identity_avatar.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A tree under an explicit accessibility setting.
///
/// The override goes in `MaterialApp.builder`, which is the one place that
/// wraps the `Navigator` rather than sitting inside it. A `MediaQuery` around
/// the app is replaced by the one the app builds from the test view; one under
/// `home` is below the routes, so a route's own transition — which is built
/// against the navigator's context — would never see it.
Widget _under({required bool reduced, required Widget child}) {
  return MaterialApp(
    builder: (context, navigator) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: navigator ?? const SizedBox(),
    ),
    home: child,
  );
}

double _opacityOf(WidgetTester tester, Key key) {
  final fade = tester.widget<FadeTransition>(
    find
        .ancestor(of: find.byKey(key), matching: find.byType(FadeTransition))
        .first,
  );
  return fade.opacity.value;
}

void main() {
  group('AppMotion', () {
    testWidgets('reads the phone\'s setting', (tester) async {
      late bool seen;
      await tester.pumpWidget(
        _under(
          reduced: true,
          child: Builder(
            builder: (context) {
              seen = AppMotion.reduced(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(seen, isTrue);
    });

    testWidgets('a duration collapses only when motion is reduced',
        (tester) async {
      late Duration still;
      late Duration moving;
      await tester.pumpWidget(
        _under(
          reduced: true,
          child: Builder(
            builder: (context) {
              still = AppMotion.duration(context, const Duration(seconds: 1));
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpWidget(
        _under(
          reduced: false,
          child: Builder(
            builder: (context) {
              moving = AppMotion.duration(context, const Duration(seconds: 1));
              return const SizedBox();
            },
          ),
        ),
      );
      expect(still, Duration.zero);
      expect(moving, const Duration(seconds: 1));
    });
  });

  group('entrances', () {
    testWidgets('still play when nothing asked them not to', (tester) async {
      await tester.pumpWidget(
        _under(
          reduced: false,
          child: const AppearAnimation(
            child: SizedBox(key: Key('row'), height: 10),
          ),
        ),
      );
      expect(_opacityOf(tester, const Key('row')), 0);
      await tester.pumpAndSettle();
      expect(_opacityOf(tester, const Key('row')), 1);
    });

    testWidgets('are simply there under Reduce Motion', (tester) async {
      await tester.pumpWidget(
        _under(
          reduced: true,
          child: const AppearAnimation(
            child: SizedBox(key: Key('row'), height: 10),
          ),
        ),
      );
      // The first frame, with no pumping: the row does not travel and does not
      // fade, so there is nothing to wait for.
      expect(_opacityOf(tester, const Key('row')), 1);
    });
  });

  group('the online dot', () {
    // The dot is on every avatar in a list, which is what makes its ticker
    // worth stopping: one repeating animation per visible row keeps the app
    // scheduling frames forever, and "peripheral, repetitive motion" is the
    // exact thing the setting is turned on to stop.
    Widget avatar() => const IdentityAvatar(
          seed: 'abc',
          label: 'Ann',
          online: true,
        );

    testWidgets('breathes while the interface is in use', (tester) async {
      await tester.pumpWidget(_under(reduced: false, child: avatar()));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isTrue);
    });

    testWidgets('holds still under Reduce Motion', (tester) async {
      await tester.pumpWidget(_under(reduced: true, child: avatar()));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });

  group('a pushed screen', () {
    Future<void> push(WidgetTester tester, {required bool reduced}) async {
      await tester.pumpWidget(
        _under(
          reduced: reduced,
          child: Builder(
            builder: (context) => CupertinoButton(
              onPressed: () => Navigator.of(context).push(
                screenRoute<void>((_) => const Text('next')),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
    }

    testWidgets('slides in from the side by default', (tester) async {
      await push(tester, reduced: false);
      expect(find.byType(CupertinoPageTransition), findsOneWidget);
    });

    testWidgets('cross-fades under Reduce Motion', (tester) async {
      await push(tester, reduced: true);
      // Replaced, not removed: the guidance asks for a fade in place of the
      // travel, because something still has to say the screen changed.
      expect(find.byType(CupertinoPageTransition), findsNothing);
      expect(find.text('next'), findsOneWidget);
    });
  });
}
