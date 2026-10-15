import 'package:cubechat/core/routing/page_transitions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A page covered by one of our slides must not be rebuilt by the cover.
///
/// The tab shell sits on a Material page, and every chat opened over it used to
/// rebuild everything in it that read an inherited widget — the hidden tabs
/// included — once on the push and once on the pop. A Galaxy S24+ log
/// (2026-10-15) had 17-85 ms of build in those frames against a 120 Hz budget
/// of 8.3. The cause was the slide's delegated transition wrapping the page
/// underneath only while it was on top: a change of shape above a page Flutter
/// keeps under a GlobalKey, which reparents it and rebuilds every dependent.
var _builds = 0;

class _ReadsTheWindow extends StatelessWidget {
  const _ReadsTheWindow();

  @override
  Widget build(BuildContext context) {
    _builds++;
    // Any inherited read will do; this is what most of the tab shell reads.
    return Text('${MediaQuery.sizeOf(context).width}');
  }
}

void main() {
  setUp(() => _builds = 0);

  testWidgets('pushing and popping a slide leaves the page under it alone',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: _ReadsTheWindow()),
      ),
    );
    final before = _builds;

    navigator.currentState!.push(
      screenRoute<void>((_) => const Scaffold(body: Text('chat'))),
    );
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();

    expect(_builds, before,
        reason: 'the page underneath was rebuilt by a slide over it');
  });

  testWidgets("a covered page's tickers still stop, and start again",
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: StillWhileCovered(
          child: Builder(
            builder: (context) {
              pageContext = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    bool ticking() => TickerMode.valuesOf(pageContext).enabled;
    expect(ticking(), isTrue);

    navigator.currentState!.push(
      screenRoute<void>((_) => const Scaffold(body: Text('chat'))),
    );
    await tester.pumpAndSettle();
    expect(ticking(), isFalse, reason: 'covered: nothing under it should tick');

    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(ticking(), isTrue, reason: 'uncovering: it ticks while it shows');
    await tester.pumpAndSettle();
  });
}
