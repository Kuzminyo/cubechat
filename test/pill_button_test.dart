import 'package:cubechat/core/widgets/pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('pill has a 48 point target and supports keyboard activation',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PillButton(label: 'Усі повідомлення', onTap: () => taps++),
          ),
        ),
      ),
    );
    expect(
      tester.getSize(find.byType(TextButton)).height,
      greaterThanOrEqualTo(48),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(taps, 1);
  });
  testWidgets('disabled pill does not respond with a press animation',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: PillButton(label: 'Недоступно'),
          ),
        ),
      ),
    );
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(PillButton)));
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      tester.widget<TextButton>(find.byType(TextButton)).onPressed,
      isNull,
    );
    expect(find.byType(AnimatedScale), findsNothing);
    await gesture.up();
  });
}
