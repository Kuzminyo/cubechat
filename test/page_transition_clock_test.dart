import 'package:cubechat/core/routing/page_transitions.dart';
import 'package:cubechat/core/util/transition_probe.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

/// A pushed screen's slide is timed from the first frame after the page was
/// built, so a heavy build is a pause before the motion rather than a jump in
/// it. See `_TimedFromFirstFrame` in `page_transitions.dart`.
void main() {
  test('why: a slow first frame is most of the start of the slide', () {
    // The curve the pushed page travels on. One 120 Hz frame moves it 3%; a
    // 25 ms frame, which is what building a conversation takes on build 1054,
    // moves it six times as far in what the eye sees as a single step.
    const curve = Curves.fastEaseInToSlowEaseOut;
    expect(curve.transform(8.3 / 300), closeTo(0.03, 0.01));
    expect(curve.transform(25 / 300), closeTo(0.18, 0.02));
  });

  Future<NavigatorState> pumpApp(WidgetTester tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('list')),
      ),
    );
    return navigatorKey.currentState!;
  }

  Future<void> expectHeldThenSmooth(
    WidgetTester tester,
    Route<void> route,
  ) async {
    // The frame that builds the page.
    await tester.pump();
    final animation = (route as TransitionRoute<void>).animation!;
    expect(animation.value, 0);
    // The next frame arrives 30 ms later, as it does after a heavy build. The
    // controller is a tenth of the way through; the page has not moved.
    await tester.pump(const Duration(milliseconds: 30));
    expect(animation.value, 0);
    expect(animation.status, AnimationStatus.forward);
    // One ordinary frame on, it has moved one ordinary frame's worth: eight
    // milliseconds of the 270 left, not thirty-eight of 300.
    await tester.pump(const Duration(milliseconds: 8));
    expect(animation.value, closeTo(8 / 270, 0.002));
    // And it still arrives when the controller says it does.
    await tester.pump(const Duration(milliseconds: 263));
    expect(animation.value, 1);
    expect(animation.status, AnimationStatus.completed);
  }

  testWidgets('a push from a tap starts moving after the page is built',
      (tester) async {
    final navigator = await pumpApp(tester);
    final route = screenRoute<void>((_) => const Text('chat'));
    navigator.push(route);
    await expectHeldThenSmooth(tester, route);
  });

  testWidgets('a push made inside a frame, as the router makes it, too',
      (tester) async {
    final navigator = await pumpApp(tester);
    final route = screenRoute<void>((_) => const Text('chat'));
    // A transient callback runs inside the frame, which is where a ticker
    // takes the frame's own timestamp as its zero.
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      navigator.push(route);
    });
    await expectHeldThenSmooth(tester, route);
  });

  testWidgets('the screen underneath stays painted, unless measured opaque',
      (tester) async {
    addTearDown(() => TransitionProbe.instance.keepUnderlay.value = true);
    final navigator = await pumpApp(tester);

    navigator.push(screenRoute<void>((_) => const Text('covering')));
    await tester.pumpAndSettle();
    expect(find.text('list'), findsOneWidget,
        reason: 'kept on stage, so closing does not repaint it from nothing');
    navigator.pop();
    await tester.pumpAndSettle();

    TransitionProbe.instance.keepUnderlay.value = false;
    navigator.push(screenRoute<void>((_) => const Text('opaque')));
    await tester.pumpAndSettle();
    expect(find.text('list'), findsNothing);
    navigator.pop();
    await tester.pumpAndSettle();
  });

  testWidgets('the list under a chat does not move, opening or closing',
      (tester) async {
    // 1067 slid it a third of the screen to the left under every chat, and
    // back on close — "the chats jerk from left to right". Up to 1066 it stood
    // still, and that is what was wanted back.
    final navigator = await pumpApp(tester);
    final atRest = tester.getTopLeft(find.text('list'));

    navigator.push(screenRoute<void>((_) => const Text('chat')));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.getTopLeft(find.text('list')), atRest);
    }
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('list')), atRest);

    navigator.pop();
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.getTopLeft(find.text('list')), atRest);
    }
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('list')), atRest);

    // A screen over a screen keeps its parallax, as it always had.
    navigator.push(screenRoute<void>((_) => const Text('chat')));
    await tester.pumpAndSettle();
    final chatAtRest = tester.getTopLeft(find.text('chat'));
    navigator.push(screenRoute<void>((_) => const Text('profile')));
    await tester.pump();
    // The slide starts on the frame after the build — see the tests above.
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.getTopLeft(find.text('chat')).dx, lessThan(chatAtRest.dx));
    await tester.pumpAndSettle();
  });

  testWidgets('a covered screen stays painted but stops animating',
      (tester) async {
    // Kept on stage for the close, it went on running its tickers under the
    // screen on top — the aurora, the dots — and the phone warmed up for it.
    final navigator = await pumpApp(tester);
    bool ticking() => TickerMode.of(tester.element(find.text('list')));
    expect(ticking(), isTrue);

    navigator.push(screenRoute<void>((_) => const Text('chat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(ticking(), isTrue, reason: 'still moving, still visible');

    await tester.pumpAndSettle();
    expect(find.text('list'), findsOneWidget, reason: 'painted underneath');
    expect(ticking(), isFalse);

    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(ticking(), isTrue, reason: 'awake again as soon as it shows');
    await tester.pumpAndSettle();
    expect(ticking(), isTrue);

    // And a screen under another pushed screen, the same.
    navigator.push(screenRoute<void>((_) => const Text('chat')));
    await tester.pumpAndSettle();
    navigator.push(screenRoute<void>((_) => const Text('profile')));
    await tester.pumpAndSettle();
    expect(TickerMode.of(tester.element(find.text('chat'))), isFalse);
    expect(TickerMode.of(tester.element(find.text('profile'))), isTrue);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(TickerMode.of(tester.element(find.text('chat'))), isTrue);
  });

  testWidgets('once open, going back is the controller exactly',
      (tester) async {
    final navigator = await pumpApp(tester);
    final route = screenRoute<void>((_) => const Text('chat'));
    navigator.push(route);
    await tester.pumpAndSettle();
    final animation = (route as TransitionRoute<void>).animation!;
    expect(animation.value, 1);

    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 190));
    // Half of the 380 ms close, with nothing held back.
    expect(animation.value, closeTo(0.5, 0.01));
    await tester.pumpAndSettle();
    expect(find.text('chat'), findsNothing);
  });
}
