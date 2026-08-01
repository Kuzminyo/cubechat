import 'package:cubechat/core/widgets/appear_animation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opacity the entrance is currently rendering at.
double _opacityOf(WidgetTester tester, Key key) {
  final fade = tester.widget<FadeTransition>(
    find.ancestor(
      of: find.byKey(key),
      matching: find.byType(FadeTransition),
    ).first,
  );
  return fade.opacity.value;
}

void main() {
  testWidgets('an enabled entrance starts invisible and fades in',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AppearAnimation(child: SizedBox(key: Key('row'), height: 10)),
      ),
    );
    expect(_opacityOf(tester, const Key('row')), 0);

    await tester.pumpAndSettle();
    expect(_opacityOf(tester, const Key('row')), 1);
  });

  testWidgets('a disabled entrance is fully there on the first frame',
      (tester) async {
    // A row scrolled into view must not fade: mid-scroll it reads as flicker,
    // and it starts a ticker exactly when the frame budget is tightest.
    await tester.pumpWidget(
      const MaterialApp(
        home: AppearAnimation(
          enabled: false,
          child: SizedBox(key: Key('row'), height: 10),
        ),
      ),
    );
    expect(_opacityOf(tester, const Key('row')), 1);
  });

  testWidgets('AppearOnce animates the first frame and nothing after',
      (tester) async {
    final seen = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: AppearOnce(
          builder: (context, animate) {
            seen.add(animate);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(seen.first, isTrue, reason: 'the list arriving should animate');
    await tester.pump();
    expect(seen.last, isFalse,
        reason: 'rows built after the first frame are scroll results');
  });
}
