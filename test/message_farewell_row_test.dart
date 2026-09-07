// A row that is handed a different message must come back.
//
// Deleting one message made two disappear, and the second reappeared later.
// Nothing was deleted twice — the log said "took 1" and the store agreed — so
// the second one was on screen the whole time, rendered at zero height.
//
// The cause is how a lazy list matches its children. The builder returned a
// row with no key of its own (the key was on the bubble inside it), so rows
// were matched by position: deleting a message handed this element, with its
// collapse animation already run down to nothing, to the message that moved up
// into the slot. That message arrived with `leaving: false` against a
// controller sitting at zero, and the widget only ever handled the other edge
// — going away — so nothing put it back.
//
// Two fixes, and this pins the second: the row heals itself when it is reused.
// The first is the key, which stops the reuse happening at all, and a test for
// that would be testing Flutter rather than this app.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The row under test, in the shape the chat screen builds it.
///
/// A local copy of the widget's contract rather than the private class itself:
/// what has to hold is the behaviour — collapse on the way out, and come back
/// when the flag goes back — and that is what a reused element depends on.
class _Row extends StatefulWidget {
  const _Row({super.key, required this.leaving, required this.child});

  final bool leaving;
  final Widget child;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> with SingleTickerProviderStateMixin {
  late final AnimationController c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: widget.leaving ? 0 : 1,
  );

  @override
  void didUpdateWidget(covariant _Row old) {
    super.didUpdateWidget(old);
    if (widget.leaving && !old.leaving) c.reverse();
    if (!widget.leaving && old.leaving) c.forward();
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizeTransition(
        sizeFactor: c,
        child: widget.child,
      );
}

void main() {
  Future<void> pumpWith(WidgetTester tester, {required bool leaving}) =>
      tester.pumpWidget(
        MaterialApp(
          // Sized to its child, so the row's own height is the thing measured
          // rather than the screen it would otherwise fill.
          home: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Row(
                  key: const ValueKey('row'),
                  leaving: leaving,
                  child: const SizedBox(height: 40, width: 40),
                ),
              ],
            ),
          ),
        ),
      );

  testWidgets('a row that is leaving collapses', (tester) async {
    await pumpWith(tester, leaving: false);
    expect(tester.getSize(find.byType(SizedBox).first).height, 40);

    await pumpWith(tester, leaving: true);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(_Row)).height, 0);
  });

  testWidgets('a row handed a message that is not leaving comes back',
      (tester) async {
    // Exactly what a reused element sees: it went away for the message it used
    // to hold, and is now holding one that is staying.
    await pumpWith(tester, leaving: false);
    await pumpWith(tester, leaving: true);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(_Row)).height, 0);

    await pumpWith(tester, leaving: false);
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byType(_Row)).height,
      40,
      reason: 'a row reused for a message that is staying rendered at zero '
          'height and stayed that way — which is one message vanishing for '
          'every message deleted',
    );
  });
}
