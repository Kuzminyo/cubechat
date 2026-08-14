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
    expect(find.byType(KeyboardSlotPanel), findsOneWidget);

    await tester.tap(find.byIcon(Icons.keyboard_alt_outlined));
    // The panel holds its space while the keyboard comes up rather than
    // blinking out and leaving a hole; with no keyboard in a test nothing ever
    // fills the slot, so the watchdog is what closes it. Pumped past both.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1200));

    expect(find.byType(KeyboardSlotPanel), findsNothing);
    expect(find.byIcon(Icons.emoji_emotions_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.emoji_emotions_outlined));
    await tester.pump();

    expect(find.byType(KeyboardSlotPanel), findsOneWidget);
  });

  testWidgets('the panel gives its space back point for point as the keyboard '
      'rises, and goes when the keyboard has it all', (tester) async {
    // The host is a Scaffold, deliberately: with resizeToAvoidBottomInset on
    // (the default) it strips the bottom inset from the MediaQuery it hands
    // down, so anything measuring the keyboard from a MediaQuery inside a chat
    // reads zero forever. Measuring the view is what makes this work at all.
    final view = tester.view;
    addTearDown(view.reset);
    addTearDown(KeyboardHeight.debugReset);
    view.devicePixelRatio = 3;
    view.viewInsets = FakeViewPadding.zero;

    await tester.pumpWidget(_host(ChatInput(
      hint: 'Message',
      sendTooltip: 'Send',
      onSend: (_) {},
      onSticker: (_, __) {},
    )));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.emoji_emotions_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final full =
        tester.getSize(find.byType(KeyboardSlotPanel)).height;
    expect(full, greaterThan(100));

    // Halfway up: the panel is holding half as much, so the two together still
    // add up to one keyboard and nothing above them moves.
    view.viewInsets = const FakeViewPadding(bottom: 150 * 3);
    await tester.pump();
    await tester.pump();
    final half = tester.getSize(find.byType(KeyboardSlotPanel)).height;
    expect(half, closeTo(full - 150, 1));

    // All the way: nothing left to draw, and the panel takes itself out rather
    // than vanishing from half-height in one frame.
    view.viewInsets = const FakeViewPadding(bottom: 300 * 3);
    await tester.pump();
    await tester.pump();
    expect(find.byType(KeyboardSlotPanel), findsNothing);
    expect(find.byIcon(Icons.emoji_emotions_outlined), findsOneWidget);

    // Let the settle timer that records the keyboard's height run out; it is a
    // static one, so leaving it pending would be flagged against this test.
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('opening on a raised keyboard grows into the space it leaves',
      (tester) async {
    final view = tester.view;
    addTearDown(view.reset);
    addTearDown(KeyboardHeight.debugReset);
    view.devicePixelRatio = 3;

    await tester.pumpWidget(_host(ChatInput(
      hint: 'Message',
      sendTooltip: 'Send',
      onSend: (_) {},
      onSticker: (_, __) {},
    )));
    await tester.pump();

    // A keyboard is up and has been measured.
    view.viewInsets = const FakeViewPadding(bottom: 300 * 3);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byIcon(Icons.emoji_emotions_outlined));
    await tester.pump();

    // Nothing is drawn yet — the keyboard still has the slot. This is the
    // "flashes and never opens" case: entering with a curve of its own, on top
    // of a keyboard that was also leaving, drew the panel twice over.
    expect(tester.getSize(find.byType(KeyboardSlotPanel)).height, lessThan(1));

    view.viewInsets = const FakeViewPadding(bottom: 150 * 3);
    await tester.pump();
    await tester.pump();
    expect(
      tester.getSize(find.byType(KeyboardSlotPanel)).height,
      closeTo(150, 1),
    );

    view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    await tester.pump();
    expect(
      tester.getSize(find.byType(KeyboardSlotPanel)).height,
      closeTo(300, 1),
    );

    // Drain the static settle timer — see the test above.
    await tester.pump(const Duration(milliseconds: 300));
  });
}
