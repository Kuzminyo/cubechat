import 'package:cubechat/core/routing/branch_container.dart';
import 'package:cubechat/core/routing/page_transitions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// A hidden tab must not be moved by a chat opened over the shell.
///
/// Build 1161 put probes inside the hidden Contacts tab on a Galaxy S24+
/// (2026-10-15): every chat open and close was followed by a 17-26 ms frame in
/// which all six probes were *activated* — deactivated and put back, which only
/// a GlobalKey moving its subtree does — and everything in the tab that read an
/// inherited widget was rebuilt for it.
var _activations = 0;
var _builds = 0;

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void activate() {
    super.activate();
    _activations++;
  }

  @override
  Widget build(BuildContext context) {
    _builds++;
    return Text('${MediaQuery.sizeOf(context).width}');
  }
}

GoRouter _router(GlobalKey<NavigatorState> root) => GoRouter(
      navigatorKey: root,
      initialLocation: '/a',
      routes: [
        StatefulShellRoute(
          pageBuilder: (context, state, shell) => shellPage(
            state: state,
            child: PopScope<void>(
              canPop: shell.currentIndex == 0,
              child: Scaffold(
                body: Stack(children: [Positioned.fill(child: shell)]),
              ),
            ),
          ),
          navigatorContainerBuilder: (context, shell, children) =>
              BranchContainer(
            currentIndex: shell.currentIndex,
            branches: children,
            onSwitch: shell.goBranch,
          ),
          branches: [
            StatefulShellBranch(
              preload: true,
              routes: [
                GoRoute(
                  path: '/a',
                  builder: (_, __) => const Hero(tag: 'x', child: Text('a')),
                ),
              ],
            ),
            StatefulShellBranch(
              preload: true,
              routes: [
                GoRoute(path: '/b', builder: (_, __) => const _Probe()),
              ],
            ),
          ],
        ),
        GoRoute(
          path: '/chat',
          parentNavigatorKey: root,
          pageBuilder: (context, state) => fadeSlidePage(
            child: const Scaffold(
              body: Hero(tag: 'x', child: Text('chat')),
            ),
            state: state,
          ),
        ),
      ],
    );

void main() {
  setUp(() {
    _activations = 0;
    _builds = 0;
  });

  testWidgets('opening and closing a chat leaves a hidden tab where it is',
      (tester) async {
    final root = GlobalKey<NavigatorState>();
    final router = _router(root);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    final builds = _builds;

    for (var i = 0; i < 3; i++) {
      router.push('/chat');
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();
    }

    expect(_activations, 0, reason: 'the hidden tab was reparented');
    expect(_builds, builds, reason: 'the hidden tab was rebuilt');
  });

  testWidgets('a chat closed by a swipe leaves a hidden tab where it is',
      (tester) async {
    // The case 1162 caught (2026-10-15): `EdgeBackGesture` holds the root
    // navigator's user-gesture flag for the length of the swipe, and Android's
    // default page transition — the one go_router put the shell in — builds a
    // different tree while that flag is up. Every tab was reparented on the
    // way in and again on the way out: `act:page` on the phone, 18-30 ms each.
    final root = GlobalKey<NavigatorState>();
    final router = _router(root);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    router.push('/chat');
    await tester.pumpAndSettle();
    final builds = _builds;

    // A swipe from the left edge, as a thumb closes a chat.
    final gesture = await tester.startGesture(const Offset(10, 300));
    for (var i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('chat'), findsNothing, reason: 'the swipe closed it');

    expect(_activations, 0, reason: 'the hidden tab was reparented');
    expect(_builds, builds, reason: 'the hidden tab was rebuilt');
  });
}
