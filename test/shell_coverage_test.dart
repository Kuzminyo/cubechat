import 'package:cubechat/core/routing/shell_coverage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// A tab screen cannot tell from its own route that a chat covers it, and the
/// router can. See [routeCoversShell].
void main() {
  testWidgets('a page pushed over the shell is seen by the router, not by the '
      "tab's route", (tester) async {
    final root = GlobalKey<NavigatorState>();
    bool? tabIsCurrent;
    final router = GoRouter(
      navigatorKey: root,
      initialLocation: '/chats',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => shell,
          branches: [
            StatefulShellBranch(routes: [
              GoRoute(
                path: '/chats',
                builder: (context, _) => Builder(
                  builder: (context) {
                    tabIsCurrent = ModalRoute.of(context)?.isCurrent;
                    return const Text('tab');
                  },
                ),
              ),
            ]),
          ],
        ),
        GoRoute(
          path: '/chat',
          parentNavigatorKey: root,
          builder: (_, __) => const Scaffold(body: Text('chat')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(routeCoversShell(router.routerDelegate.currentConfiguration), isFalse);

    router.push('/chat');
    await tester.pumpAndSettle();
    expect(routeCoversShell(router.routerDelegate.currentConfiguration), isTrue);
    // The reason this exists: the tab's own route still says it is on top,
    // which is what the chats list used to ask.
    expect(tabIsCurrent, isTrue);

    router.pop();
    await tester.pumpAndSettle();
    expect(routeCoversShell(router.routerDelegate.currentConfiguration), isFalse);
  });
}
