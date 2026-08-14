import 'package:cubechat/features/chat/presentation/widgets/mention_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every span the widget drew, with whether it is tappable.
List<(String, bool)> _spans(WidgetTester tester) {
  final rich = tester.widget<Text>(find.byType(Text));
  final out = <(String, bool)>[];
  void walk(InlineSpan span) {
    if (span is TextSpan) {
      if (span.text != null) {
        out.add((span.text!, span.recognizer is TapGestureRecognizer));
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }
  }

  walk(rich.textSpan!);
  return out;
}

Future<void> _pump(WidgetTester tester, String text) => tester.pumpWidget(
      MaterialApp(home: Scaffold(body: MentionText(text))),
    );

void main() {
  testWidgets('a link is tappable and the words around it are not',
      (tester) async {
    await _pump(tester, 'смотри https://example.com/a вот тут');
    expect(_spans(tester), [
      ('смотри ', false),
      ('https://example.com/a', true),
      (' вот тут', false),
    ]);
  });

  testWidgets('www without a scheme counts too', (tester) async {
    await _pump(tester, 'www.example.com');
    expect(_spans(tester).single.$2, isTrue);
  });

  testWidgets('the full stop ending the sentence is not part of the link',
      (tester) async {
    await _pump(tester, 'тут https://example.com.');
    expect(_spans(tester), [
      ('тут ', false),
      ('https://example.com', true),
      // Trimmed, but still drawn: the message reads exactly as it was sent.
      ('.', false),
    ]);
  });

  testWidgets('a bracket the link opened itself is kept', (tester) async {
    await _pump(tester, 'https://ru.wikipedia.org/wiki/Дом_(значения)');
    expect(_spans(tester).single.$1, endsWith(')'));
  });

  testWidgets('prose with dots in it is not a link', (tester) async {
    await _pump(tester, 'фото.jpg и 1.5 метра.Точка');
    expect(_spans(tester).every((s) => !s.$2), isTrue);
  });

  testWidgets('mentions still stand out and stay untappable', (tester) async {
    await _pump(tester, 'привет @kuzya');
    expect(_spans(tester).last, ('@kuzya', false));
  });
}
