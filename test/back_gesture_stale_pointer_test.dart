import 'package:cubechat/core/routing/page_transitions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// A touch the app never hears the end of must not hold the back gesture.
///
/// Leaving an iPhone app is itself a gesture — the swipe up from the home
/// indicator — and it starts as a touch inside the app. When the system takes
/// it over, the app is not always told the finger lifted. The drag recognizer
/// covering the page goes on tracking that pointer, and a drag only ends when
/// every pointer it tracks has: so the next swipe back after returning moved
/// the page and then never finished. "Выход из чата зависает на полпути,
/// рандомно, когда с фона заходишь на iOS."
void main() {
  GoRouter router() => GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            pageBuilder: (context, state) => fadeSlidePage(
              state: state,
              child: Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => context.push('/chat'),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/chat',
            pageBuilder: (context, state) => fadeSlidePage(
              state: state,
              child: const Scaffold(body: Center(child: Text('chat'))),
            ),
          ),
        ],
      );

  Future<void> openChat(WidgetTester tester) async {
    final r = router();
    addTearDown(r.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: r));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('chat'), findsOneWidget);
  }

  double? chatLeft(WidgetTester tester) {
    final chat = find.text('chat');
    if (chat.evaluate().isEmpty) return null;
    return tester.getCenter(chat).dx - 400;
  }

  Future<void> swipeBack(WidgetTester tester, double distance) async {
    final gesture = await tester.startGesture(const Offset(200, 300));
    for (var moved = 0.0; moved < distance; moved += 20) {
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
  }

  testWidgets('a touch that left upwards and never lifted', (tester) async {
    await openChat(tester);
    final centre = tester.getCenter(find.text('chat')).dx;

    // The swipe up to go home: down near the bottom, up, and then nothing —
    // the system has it now.
    final lost = await tester.startGesture(const Offset(200, 590));
    for (var i = 0; i < 6; i++) {
      await lost.moveBy(const Offset(0, -30));
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Away, and back.
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();

    // Back in the app: a swipe back far past the commit point.
    await swipeBack(tester, 360);
    await tester.pumpAndSettle();

    expect(find.text('chat'), findsNothing,
        reason: 'the page was left at '
            '${find.text('chat').evaluate().isEmpty ? '-' : tester.getCenter(find.text('chat')).dx - centre}');
    expect(chatLeft(tester), isNull);
  });

  testWidgets('a back swipe cut off by the app going away settles',
      (tester) async {
    await openChat(tester);
    final centre = tester.getCenter(find.text('chat')).dx;

    final cut = await tester.startGesture(const Offset(200, 300));
    for (var i = 0; i < 6; i++) {
      await cut.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.getCenter(find.text('chat')).dx, greaterThan(centre + 60));

    // The app goes to the background mid-swipe and the finger's end is never
    // delivered.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(tester.getCenter(find.text('chat')).dx, centre,
        reason: 'back where it was, not stopped where the finger was');

    // And the next swipe back works.
    await swipeBack(tester, 360);
    await tester.pumpAndSettle();
    expect(find.text('chat'), findsNothing);
  });
}
