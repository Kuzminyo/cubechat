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

  /// Two scopes on one route, which is what the chat screen actually has: one
  /// that redirects to the chats list because there is nothing underneath it,
  /// and one around the composer that cancels a message selection.
  ///
  /// Flutter reports a blocked pop to *every* scope on the route, not only to
  /// whichever one blocked it. So the redirect cannot tell "back was pressed
  /// with nothing to pop" from "back was pressed at a mode that consumed it" —
  /// and on a chat opened from search, where the redirect's own `canPop` is
  /// already false, a back press aimed at a selection cleared the selection
  /// *and* left the chat.
  group('a route carrying two pop scopes', () {
    /// The chat screen's shape, with nothing under the route so that
    /// `Navigator.canPop()` is false the way it is for a chat opened from
    /// search onto an empty stack.
    Future<({List<String> events, ValueGetter<bool> selecting})> pumpChat(
      WidgetTester tester, {
      required bool startSelecting,
      required bool guarded,
    }) async {
      final events = <String>[];
      var selecting = startSelecting;

      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              final canPop = Navigator.of(context).canPop();
              return PopScope<void>(
                canPop: canPop,
                onPopInvokedWithResult: (didPop, _) {
                  if (didPop || canPop) return;
                  // The guard under test. Without it the redirect fires for a
                  // back press somebody else blocked.
                  if (guarded && selecting) return;
                  events.add('redirect');
                },
                child: PopScope<void>(
                  canPop: !selecting,
                  onPopInvokedWithResult: (didPop, _) {
                    if (didPop || !selecting) return;
                    events.add('clear-selection');
                    setState(() => selecting = false);
                  },
                  child: const Scaffold(
                    body: Center(child: Text('chat')),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (events: events, selecting: () => selecting);
    }

    testWidgets('reports one blocked pop to both of them', (tester) async {
      // The behaviour the guard exists because of. If this ever stops being
      // true the guard is merely redundant, not wrong — but it is true, and it
      // is the whole reason the redirect needs to ask about the selection.
      final chat = await pumpChat(
        tester,
        startSelecting: true,
        guarded: false,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(chat.events, containsAll(<String>['clear-selection', 'redirect']),
          reason: 'a blocked pop reaches every scope registered on the route');
    });

    testWidgets('back at a selection cancels it and stays in the chat',
        (tester) async {
      final chat = await pumpChat(
        tester,
        startSelecting: true,
        guarded: true,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(chat.selecting(), isFalse,
          reason: 'the back press was meant for the selection');
      expect(chat.events, isNot(contains('redirect')),
          reason: 'and cancelling a selection is not a reason to leave');
      expect(find.text('chat'), findsOneWidget);
    });

    testWidgets('back with nothing selected still redirects', (tester) async {
      final chat = await pumpChat(
        tester,
        startSelecting: false,
        guarded: true,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(chat.events, contains('redirect'),
          reason: 'with no mode to consume it, back leaves for the chats list');
    });
  });
}
