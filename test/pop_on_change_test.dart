import 'package:cubechat/core/widgets/pop_on_change.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scale the pop is currently rendering at.
double _scaleOf(WidgetTester tester) =>
    tester.widget<ScaleTransition>(find.byType(ScaleTransition)).scale.value;

/// Pumps a [PopOnChange] and hands back a way to rebuild it with a new value,
/// without ever replacing the element — which is the distinction the whole
/// widget turns on.
Future<void> _pump(
  WidgetTester tester, {
  required Object value,
  bool initialPop = false,
}) =>
    tester.pumpWidget(
      MaterialApp(
        home: PopOnChange(
          value: value,
          initialPop: initialPop,
          child: const SizedBox(key: Key('chip'), height: 10),
        ),
      ),
    );

void main() {
  testWidgets('a first build does not pop', (tester) async {
    // The rule the message list depends on: a bubble scrolled back into view is
    // a new widget, and anything animating from initState replays itself
    // mid-scroll.
    await _pump(tester, value: 3);
    expect(_scaleOf(tester), 1);

    await tester.pump(const Duration(milliseconds: 120));
    expect(_scaleOf(tester), 1, reason: 'and it stays still afterwards');
  });

  testWidgets('a changed value swells past 1 and settles back', (tester) async {
    await _pump(tester, value: 3);
    await _pump(tester, value: 4);

    // Partway up the first leg of the arc.
    await tester.pump(const Duration(milliseconds: 80));
    expect(_scaleOf(tester), greaterThan(1));

    await tester.pumpAndSettle();
    expect(_scaleOf(tester), moreOrLessEquals(1, epsilon: 0.001));
  });

  testWidgets('rebuilding with the same value does nothing', (tester) async {
    await _pump(tester, value: 3);
    await _pump(tester, value: 3);
    await tester.pump(const Duration(milliseconds: 80));
    expect(_scaleOf(tester), 1);
  });

  testWidgets('initialPop animates the first build after all', (tester) async {
    // The case the rule gets wrong on its own: a reaction chip that did not
    // exist a frame ago has no previous value to differ from, and its arrival
    // is the change worth showing. Only the parent can tell that apart from a
    // scroll, so it says so.
    await _pump(tester, value: 3, initialPop: true);
    await tester.pump(const Duration(milliseconds: 80));
    expect(_scaleOf(tester), greaterThan(1));

    await tester.pumpAndSettle();
    expect(_scaleOf(tester), moreOrLessEquals(1, epsilon: 0.001));
  });

  testWidgets('a second change restarts the arc rather than being swallowed',
      (tester) async {
    await _pump(tester, value: 1);
    await _pump(tester, value: 2);
    await tester.pumpAndSettle();
    expect(_scaleOf(tester), moreOrLessEquals(1, epsilon: 0.001));

    // Two reactions landing back to back are two events, and the controller
    // sitting at the end of its run must not eat the second one.
    await _pump(tester, value: 3);
    await tester.pump(const Duration(milliseconds: 80));
    expect(_scaleOf(tester), greaterThan(1));
  });
}
