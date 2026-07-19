import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The floating composer lets the conversation scroll underneath it, and keeps
/// the newest message clear by padding the list by the composer's height.
///
/// That rests on an assumption worth pinning down rather than trusting: the
/// message list is built with `reverse: true`, and it is not obvious that
/// `EdgeInsets.bottom` still means "the visual bottom" once the scroll axis is
/// flipped. If it resolved against the scroll direction instead, the padding
/// would land at the top and the newest message — the one the user just sent —
/// would sit hidden behind the composer. That is precisely the bug the padding
/// exists to prevent, so it gets a test.
void main() {
  const composerHeight = 80.0;
  const clearance = 12.0;
  const itemHeight = 40.0;

  // Keyed because Scaffold builds a Stack of its own, and find.byType would
  // match both.
  const stackKey = ValueKey<String>('composer-stack');

  Widget harness({required int items}) => MaterialApp(
        home: Scaffold(
          body: Stack(
            key: stackKey,
            children: [
              ListView.builder(
                reverse: true,
                padding: const EdgeInsets.only(
                  top: clearance,
                  bottom: composerHeight + clearance,
                ),
                itemCount: items,
                itemBuilder: (_, i) => SizedBox(
                  height: itemHeight,
                  child: Text('item $i', key: ValueKey<int>(i)),
                ),
              ),
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SizedBox(height: composerHeight),
              ),
            ],
          ),
        ),
      );

  testWidgets('the newest message clears the composer', (tester) async {
    await tester.pumpWidget(harness(items: 3));

    final viewportBottom = tester.getRect(find.byKey(stackKey)).bottom;
    // In a reversed list index 0 is the newest message, drawn at the visual
    // bottom — the one at risk of hiding behind the composer.
    final newest = tester.getRect(find.byKey(const ValueKey<int>(0)));

    expect(
      newest.bottom,
      lessThanOrEqualTo(viewportBottom - composerHeight),
      reason: 'the newest message is behind the composer — bottom padding did '
          'not land at the visual bottom of a reversed list',
    );
    expect(
      newest.bottom,
      closeTo(viewportBottom - composerHeight - clearance, 0.5),
      reason: 'the gap above the composer should be exactly the clearance',
    );
  });

  testWidgets('a conversation too short to scroll still clears it',
      (tester) async {
    // The degenerate case: with one message the list does not fill the
    // viewport, and a padding applied to the wrong edge would go unnoticed
    // until someone sent a second message.
    await tester.pumpWidget(harness(items: 1));

    final viewportBottom = tester.getRect(find.byKey(stackKey)).bottom;
    final only = tester.getRect(find.byKey(const ValueKey<int>(0)));

    expect(only.bottom, lessThanOrEqualTo(viewportBottom - composerHeight));
  });
}
