import 'package:cubechat/features/chat/presentation/widgets/chat_input.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: child)),
    );

void main() {
  testWidgets('edit mode prefills the field and shows the banner',
      (tester) async {
    await tester.pumpWidget(_host(ChatInput(
      hint: 'Message',
      sendTooltip: 'Send',
      onSend: (_) {},
      editingText: 'original text',
      onEditCommit: (_) {},
      onEditCancel: () {},
    )));
    await tester.pump();

    // Banner label + the message text (field + banner preview).
    expect(find.text('Edit message'), findsOneWidget);
    expect(find.text('original text'), findsWidgets);
    // The commit affordance is a check, not the send arrow.
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward), findsNothing);
  });

  testWidgets('sending in edit mode commits, not sends', (tester) async {
    String? committed;
    String? sent;
    await tester.pumpWidget(_host(ChatInput(
      hint: 'Message',
      sendTooltip: 'Send',
      onSend: (v) => sent = v,
      editingText: 'before',
      onEditCommit: (v) => committed = v,
      onEditCancel: () {},
    )));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'after');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.check));
    await tester.pump();

    expect(committed, 'after');
    expect(sent, isNull);
  });

  testWidgets('the banner close button cancels the edit', (tester) async {
    var cancelled = false;
    await tester.pumpWidget(_host(ChatInput(
      hint: 'Message',
      sendTooltip: 'Send',
      onSend: (_) {},
      editingText: 'x',
      onEditCommit: (_) {},
      onEditCancel: () => cancelled = true,
    )));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(cancelled, isTrue);
  });

  testWidgets('outside edit mode the send arrow is used', (tester) async {
    String? sent;
    await tester.pumpWidget(_host(ChatInput(
      hint: 'Message',
      sendTooltip: 'Send',
      onSend: (v) => sent = v,
    )));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNothing);

    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    expect(sent, 'hello');
  });
}
