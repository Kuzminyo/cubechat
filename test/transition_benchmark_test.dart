import 'dart:async';

import 'package:cubechat/core/util/transition_probe.dart';
import 'package:cubechat/features/profile/data/transition_benchmark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// What the chat screen saw as each open was built.
class _Chat extends StatefulWidget {
  const _Chat(this.seen);

  final List<bool> seen;

  @override
  State<_Chat> createState() => _ChatState();
}

class _ChatState extends State<_Chat> {
  @override
  void initState() {
    super.initState();
    widget.seen.add(TransitionProbe.instance.placeholderMedia.value);
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('chat'));
}

/// The scripted open-and-close run behind the Diagnostics "scripted run" row.
void main() {
  late List<bool> seen;
  late GoRouter router;

  Future<void> pumpApp(WidgetTester tester) async {
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
  }

  Future<void> elapse(WidgetTester tester, Duration total) async {
    const step = Duration(milliseconds: 100);
    for (var t = Duration.zero; t < total; t += step) {
      await tester.pump(step);
    }
  }

  testWidgets('opens from the chat list, alternating, and comes back',
      (tester) async {
    await pumpApp(tester);
    final bench = TransitionBenchmark.instance;
    unawaited(bench.run(router: router, chat: '/chat/a', rounds: 2));
    await tester.pump();
    expect(bench.running, isTrue);

    await elapse(tester, const Duration(seconds: 16));

    expect(bench.running, isFalse);
    // One unmeasured warm-up, then normal and placeholders taking turns.
    expect(seen, [false, false, true, false, true]);
    expect(find.text('diagnostics'), findsOneWidget);
    final probe = TransitionProbe.instance;
    expect(probe.placeholderMedia.value, isFalse, reason: 'put back');
    expect(probe.scripted, isFalse);
    expect(probe.armed.value, isFalse, reason: 'it was not armed before');
  });

  testWidgets('a touch stops it', (tester) async {
    await pumpApp(tester);
    final bench = TransitionBenchmark.instance;
    unawaited(bench.run(router: router, chat: '/chat/a', rounds: 5));
    await elapse(tester, const Duration(seconds: 4));
    expect(bench.running, isTrue);

    await tester.tapAt(const Offset(20, 300));
    await elapse(tester, const Duration(seconds: 3));

    expect(bench.running, isFalse);
    expect(seen.length, lessThan(3));
    expect(TransitionProbe.instance.placeholderMedia.value, isFalse);
    await tester.pumpAndSettle();
    expect(find.text('diagnostics'), findsOneWidget);
  });
}
