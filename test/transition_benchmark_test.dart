import 'dart:async';

import 'package:cubechat/core/theme/glass.dart';
import 'package:cubechat/core/util/transition_probe.dart';
import 'package:cubechat/features/profile/data/transition_benchmark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// How the chat screen found the experiments as each open was built.
typedef _Seen = ({bool grouped, bool blur});

class _Chat extends StatefulWidget {
  const _Chat(this.seen);

  final List<_Seen> seen;

  @override
  State<_Chat> createState() => _ChatState();
}

class _ChatState extends State<_Chat> {
  @override
  void initState() {
    super.initState();
    widget.seen.add((grouped: AppBlur.groupedPanes, blur: AppBlur.panes));
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('chat'));
}

/// The scripted open-and-close run behind the Diagnostics "scripted run" row.
void main() {
  late List<_Seen> seen;
  late GoRouter router;

  Future<OverlayState> pumpApp(WidgetTester tester) async {
    seen = [];
    router = GoRouter(
      initialLocation: '/diagnostics',
      routes: [
        GoRoute(
          path: '/chats',
          builder: (_, __) => const Scaffold(body: Text('list')),
        ),
        GoRoute(path: '/chat/:id', builder: (_, __) => _Chat(seen)),
        GoRoute(
          path: '/diagnostics',
          builder: (_, __) => const Scaffold(body: Text('diagnostics')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    return tester.state<OverlayState>(find.byType(Overlay).first);
  }

  Future<void> elapse(WidgetTester tester, Duration total) async {
    const step = Duration(milliseconds: 100);
    for (var t = Duration.zero; t < total; t += step) {
      await tester.pump(step);
    }
  }

  const asIs = (grouped: false, blur: true);

  testWidgets('every variant takes its turn, and everything is put back',
      (tester) async {
    final overlay = await pumpApp(tester);
    final bench = TransitionBenchmark.instance;
    unawaited(
      bench.run(router: router, overlay: overlay, chat: '/chat/a', rounds: 1),
    );
    await tester.pump();
    expect(bench.running, isTrue);
    expect(find.textContaining('hands off'), findsOneWidget,
        reason: 'it says it is running from the first moment');

    await elapse(tester, const Duration(seconds: 14));

    expect(bench.running, isFalse);
    expect(seen, [
      asIs, // warm-up, unmeasured
      asIs,
      (grouped: false, blur: false),
      (grouped: true, blur: true),
    ]);
    expect(find.textContaining('hands off'), findsNothing);
    expect(find.text('diagnostics'), findsOneWidget);
    final probe = TransitionProbe.instance;
    expect(probe.placeholderMedia.value, isFalse);
    expect(probe.instantTransitions.value, isFalse);
    expect(AppBlur.panes, isTrue);
    expect(AppBlur.groupedPanes, isFalse);
    expect(probe.scripted, isFalse);
    expect(probe.armed.value, isFalse, reason: 'it was not armed before');
  });

  testWidgets('a touch lands on the sheet, not the app, and stops the run',
      (tester) async {
    final overlay = await pumpApp(tester);
    final bench = TransitionBenchmark.instance;
    unawaited(
      bench.run(router: router, overlay: overlay, chat: '/chat/a', rounds: 5),
    );
    await elapse(tester, const Duration(seconds: 4));
    expect(bench.running, isTrue);

    await tester.tapAt(const Offset(20, 300));
    await elapse(tester, const Duration(seconds: 3));

    expect(bench.running, isFalse);
    expect(seen.length, lessThan(3));
    expect(TransitionProbe.instance.placeholderMedia.value, isFalse);
    expect(AppBlur.panes, isTrue);
    await tester.pumpAndSettle();
    expect(find.text('diagnostics'), findsOneWidget);
  });
}
