import 'package:cubechat/features/chat/presentation/widgets/chat_input.dart';
import 'package:cubechat/features/chat/presentation/widgets/emoji_sticker_panel.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward_rounded), findsNothing);
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
    await tester.tap(find.byIcon(Icons.check_rounded));
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

    await tester.tap(find.byIcon(Icons.close_rounded));
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
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsNothing);

    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
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
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
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
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
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
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
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

    await tester.tap(find.byIcon(Icons.emoji_emotions_rounded));
    await tester.pump();
    expect(find.byType(KeyboardSlotPanel), findsOneWidget);

    await tester.tap(find.byIcon(Icons.keyboard_alt_rounded));
    // The panel holds its space while the keyboard comes up rather than
    // blinking out and leaving a hole; with no keyboard in a test nothing ever
    // fills the slot, so the watchdog is what closes it. Pumped past both.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1200));

    expect(find.byType(KeyboardSlotPanel), findsNothing);
    expect(find.byIcon(Icons.emoji_emotions_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.emoji_emotions_rounded));
    await tester.pump();

    expect(find.byType(KeyboardSlotPanel), findsOneWidget);
  });

  testWidgets(
      'the panel gives its space back point for point as the keyboard '
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

    await tester.tap(find.byIcon(Icons.emoji_emotions_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final full = tester.getSize(find.byType(KeyboardSlotPanel)).height;
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
    expect(find.byIcon(Icons.emoji_emotions_rounded), findsOneWidget);

    // Let the settle timer that records the keyboard's height run out; it is a
    // static one, so leaving it pending would be flagged against this test.
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('a keyboard shorter than the tallest one still takes the slot',
      (tester) async {
    // The reported bug. The panel sizes itself against the tallest keyboard
    // ever seen; a shorter one — the same keyboard with its suggestion strip
    // hidden, another language, a one-handed layout — leaves forty-odd points
    // over. The takeover used to wait for *no* room at all, so it never fired
    // and the panel drew its top forty points: the Emoji/Stickers tab strip,
    // stranded between the composer and the keyboard.
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

    // A tall keyboard comes up and is remembered, then goes away.
    view.viewInsets = const FakeViewPadding(bottom: 320 * 3);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byIcon(Icons.emoji_emotions_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(KeyboardSlotPanel), findsOneWidget);

    // Now a keyboard forty points shorter than the remembered one.
    view.viewInsets = const FakeViewPadding(bottom: 280 * 3);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byType(KeyboardSlotPanel),
      findsNothing,
      reason: 'the leftover room is less than a panel, so the keyboard has it',
    );

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

    await tester.tap(find.byIcon(Icons.emoji_emotions_rounded));
    await tester.pump();

    // Nothing is drawn yet — the keyboard still has the slot. This is the
    // "flashes and never opens" case: entering with a curve of its own, on top
    // of a keyboard that was also leaving, drew the panel twice over.
    expect(tester.getSize(find.byType(KeyboardSlotPanel)).height, lessThan(1));

    // Long pumps between the steps on purpose: a keyboard on its way out passes
    // through every height there is, and if any of those counted as a
    // measurement the panel would end up the size of the last frame before the
    // keyboard vanished — and would decide it had been taken over on the way.
    view.viewInsets = const FakeViewPadding(bottom: 150 * 3);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(KeyboardSlotPanel), findsOneWidget);
    expect(
      tester.getSize(find.byType(KeyboardSlotPanel)).height,
      closeTo(150, 1),
    );

    view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(KeyboardSlotPanel), findsOneWidget);
    expect(
      tester.getSize(find.byType(KeyboardSlotPanel)).height,
      closeTo(300, 1),
    );

    // Drain the static settle timer — see the test above.
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('an open panel is announced, so the route can answer for it',
      (tester) async {
    // Whether the panel is open is this widget's own state, and the back press
    // that closes it is reported to every PopScope on the route — including
    // the redirect at the top of a chat opened from search, which read it as
    // "nothing underneath, leave for the chats list" and did both at once.
    // The redirect can only decline if it is told the panel took that press.
    final reports = <bool>[];
    await tester.pumpWidget(_host(ChatInput(
      hint: 'Message',
      sendTooltip: 'Send',
      onSend: (_) {},
      onSticker: (_, __) {},
      onPanelOpenChanged: reports.add,
    )));
    await tester.pump();
    expect(reports, isEmpty, reason: 'nothing has happened yet');

    await tester.tap(find.byIcon(Icons.emoji_emotions_rounded));
    await tester.pump();
    expect(find.byType(KeyboardSlotPanel), findsOneWidget);
    expect(reports, <bool>[true]);

    await tester.binding.handlePopRoute();
    await tester.pump();
    // The panel folds before it leaves the tree, and the flag drops with it.
    await tester.pump(KeyboardSlotPanel.motion + const Duration(seconds: 1));

    expect(find.byType(KeyboardSlotPanel), findsNothing);
    expect(reports, <bool>[true, false],
        reason: 'a flag nobody lowers is worse than no flag at all');
  });

  testWidgets('sending answers the finger before the radio can', (tester) async {
    // The most repeated touch in the app, and the only one that had nothing to
    // say in the hand. A message leaves over a radio, so nothing is going to
    // confirm anything inside the same second; the tick is the app saying
    // "taken" at the moment the finger commits.
    final taps = <String?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          taps.add(call.arguments as String?);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(_host(ChatInput(
      hint: 'Message',
      sendTooltip: 'Send',
      onSend: (_) {},
    )));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(taps, isEmpty, reason: 'typing is not a commitment');

    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();

    expect(taps, ['HapticFeedbackType.lightImpact'],
        reason: 'light, because a long press opening the spotlight is the '
            'heavier one and a send must not outrank it');
  });

  testWidgets('a composer that goes away lowers the flag on its way out',
      (tester) async {
    // The regression this exists for. The composer is remounted whenever the
    // row above it appears — a reply bar, the unblock island — because that
    // moves it from being the bar to being a child of a Column, and Flutter
    // rebuilds the subtree rather than reparenting it. Open the panel, tap
    // Reply, and the old State was disposed still holding `_panelOpen: true`
    // with nothing to lower the copy the route reads. The chat's back
    // handling then declined every press, believing a panel was open that was
    // no longer even in the tree.
    final reports = <bool>[];
    await tester.pumpWidget(_host(ChatInput(
      hint: 'Message',
      sendTooltip: 'Send',
      onSend: (_) {},
      onSticker: (_, __) {},
      onPanelOpenChanged: reports.add,
    )));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.emoji_emotions_rounded));
    await tester.pump();
    expect(reports, <bool>[true]);

    // The remount: the same widget, one level deeper. Flutter disposes the
    // State rather than moving it.
    await tester.pumpWidget(_host(Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('reply bar'),
        ChatInput(
          hint: 'Message',
          sendTooltip: 'Send',
          onSend: (_) {},
          onSticker: (_, __) {},
          onPanelOpenChanged: reports.add,
        ),
      ],
    )));
    await tester.pump();

    expect(reports, <bool>[true, false],
        reason: 'a flag outlives the widget that raised it unless it is '
            'lowered where the widget ends');
  });

  testWidgets('a panel taken over by the keyboard is announced too',
      (tester) async {
    // The other way out of the panel, and the one that does not go through
    // [closePanel]: the keyboard rises into the slot and the panel leaves.
    final view = tester.view;
    addTearDown(view.reset);
    addTearDown(KeyboardHeight.debugReset);
    view.devicePixelRatio = 3;
    view.viewInsets = FakeViewPadding.zero;

    final reports = <bool>[];
    await tester.pumpWidget(_host(ChatInput(
      hint: 'Message',
      sendTooltip: 'Send',
      onSend: (_) {},
      onSticker: (_, __) {},
      onPanelOpenChanged: reports.add,
    )));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.emoji_emotions_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(reports, <bool>[true]);

    view.viewInsets = const FakeViewPadding(bottom: 300 * 3);
    await tester.pump();
    await tester.pump();

    expect(find.byType(KeyboardSlotPanel), findsNothing);
    expect(reports, <bool>[true, false]);

    // Drain the static settle timer — see the tests above.
    await tester.pump(const Duration(milliseconds: 300));
  });
}
