import 'package:cubechat/features/chat/presentation/widgets/chat_input.dart';
import 'package:cubechat/features/chat/presentation/widgets/emoji_sticker_panel.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => ProviderScope(
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Align(alignment: Alignment.bottomCenter, child: child),
        ),
      ),
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

  testWidgets('a new message starts with system sentence capitalization',
      (tester) async {
    await tester.pumpWidget(_host(ChatInput(
      hint: 'Message',
      sendTooltip: 'Send',
      onSend: (_) {},
    )));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
    expect(field.textCapitalization, TextCapitalization.sentences);
  });

  testWidgets('an existing draft is restored into the composer',
      (tester) async {
    await tester.pumpWidget(_host(ChatInput(
      hint: 'Message',
      sendTooltip: 'Send',
      initialText: 'unfinished message',
      onSend: (_) {},
    )));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'unfinished message');
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
  });

  testWidgets('typing updates the draft and sending clears it', (tester) async {
    final changes = <String>[];
    await tester.pumpWidget(_host(ChatInput(
      hint: 'Message',
      sendTooltip: 'Send',
      initialText: 'old',
      onChanged: changes.add,
      onSend: (_) {},
    )));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'new draft');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();

    expect(changes, contains('new draft'));
    expect(changes.last, isEmpty);
  });
  testWidgets(
      'keyboard button replaces the emoji/sticker panel instead of stacking under it',
      (tester) async {
    Widget input() => ChatInput(
          hint: 'Message',
          sendTooltip: 'Send',
          onSend: (_) {},
          onSticker: (_, __) {},
        );

    await tester.pumpWidget(_host(input()));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.emoji_emotions_outlined));
    await tester.pump();
    expect(find.byType(AnimatedEmojiStickerPanel), findsOneWidget);

    await tester.tap(find.byIcon(Icons.keyboard_alt_outlined));
    await tester.pump();

    expect(find.byType(AnimatedEmojiStickerPanel), findsNothing);
    expect(find.byIcon(Icons.emoji_emotions_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.emoji_emotions_outlined));
    await tester.pump();

    expect(find.byType(AnimatedEmojiStickerPanel), findsOneWidget);
  });
}
