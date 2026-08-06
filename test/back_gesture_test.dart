import 'package:cubechat/core/routing/page_transitions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// The drag-back gesture, driven through the same stack the app uses:
/// go_router pages built by [fadeSlidePage].
///
/// It is worth testing here rather than on a phone because the failure mode is
/// silent — the page follows the finger either way, and what "does not work"
/// means is that letting go puts it back. That is one boolean deep in the
/// gesture, and a widget test can see it.
void main() {
  Widget app(GoRouter router) => MaterialApp.router(routerConfig: router);

  GoRouter twoScreens({bool blockPop = false}) => GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            pageBuilder: (context, state) => fadeSlidePage(
              state: state,
              child: Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => context.push('/second'),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/second',
            pageBuilder: (context, state) => fadeSlidePage(
              state: state,
              child: Scaffold(
                body: blockPop
                    // What the chat screen does when it was opened from search:
                    // it has somewhere specific to land on back. The condition
                    // is the point — `canPop: false` unconditionally is what
                    // used to switch the drag off for that screen entirely.
                    // The Builder matters: asked from the page builder's own
                    // context — above the Navigator — `canPop` has nothing to
                    // read during the first build and answers no, which is the
                    // trap the chat screen fell into.
                    ? Builder(
                        builder: (context) => PopScope<void>(
                        canPop: Navigator.of(context).canPop(),
                        onPopInvokedWithResult: (didPop, _) {
                          if (!didPop) context.go('/');
                        },
                        child: const Center(child: Text('second')),
                      ),
                      )
                    : const Center(child: Text('second')),
              ),
            ),
          ),
        ],
      );

  Future<void> open(WidgetTester tester, GoRouter router) async {
    await tester.pumpWidget(app(router));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);
  }

  /// A drag that starts away from the leading edge, moves right in steps (so
  /// the recognizer sees real movement rather than one teleport), and lets go.
  Future<void> dragBack(
    WidgetTester tester, {
    required double from,
    required double distance,
  }) async {
    final gesture = await tester.startGesture(Offset(from, 400));
    for (var moved = 0.0; moved < distance; moved += 20) {
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('a drag from the middle of the page goes back', (tester) async {
    final router = twoScreens();
    await open(tester, router);

    // Half the screen, well past the third that commits the pop.
    await dragBack(tester, from: 200, distance: 400);

    expect(find.text('second'), findsNothing,
        reason: 'letting go past the commit point should leave the page');
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('a short drag springs back instead of leaving', (tester) async {
    final router = twoScreens();
    await open(tester, router);

    await dragBack(tester, from: 200, distance: 60);

    expect(find.text('second'), findsOneWidget);
  });

  testWidgets('a screen with its own back handling can still be dragged',
      (tester) async {
    // The chat screen opened from search carries a PopScope so that back lands
    // on the chats list. Flutter disables the drag for any route whose
    // PopScope says it may not pop — so while that was unconditional, the page
    // did not move at all on the one screen people swipe from most.
    final router = twoScreens(blockPop: true);
    await open(tester, router);

    await dragBack(tester, from: 200, distance: 400);

    expect(find.text('second'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });
}
