import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/presentation/widgets/message_bubble.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A reaction on somebody else's message sits at the left of its bubble, the
/// way Telegram draws it — not huddled against the clock at the right, which
/// on a long message put it a whole line's width away from where the text
/// starts.
Message _theirs({required bool mine}) => Message(
      id: 'm1',
      chatId: 'peer',
      text: 'a message long enough to make its bubble properly wide on screen',
      sentAt: DateTime(2026, 10, 1, 10, 11),
      isMine: mine,
      reactions: const {
        '👍': {'abcdef0123456789'},
      },
    );

Future<void> _pump(WidgetTester tester, Message m) async {
  tester.view.physicalSize = const Size(1080, 2000);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: MessageBubble(message: m, chatId: 'peer')),
      ),
    ),
  );
  await tester.pump();
}

/// The drawn reaction — the overlay's, not the invisible copy that holds the
/// bubble's size.
Rect _reaction(WidgetTester tester) =>
    tester.getRect(find.text('👍').hitTestable().first);

void main() {
  testWidgets('on theirs the reaction starts where the text starts',
      (tester) async {
    await _pump(tester, _theirs(mine: false));
    final text = tester.getRect(find.textContaining('a message long enough'));
    final reaction = _reaction(tester);
    final clock = tester.getRect(find.text('10:11').hitTestable().first);
    // The emoji sits inside its chip after the reactor's face, ~25 px in;
    // huddled by the clock it was 155.
    expect(reaction.left - text.left, lessThan(40),
        reason: 'the reaction is at the left of the bubble');
    expect(clock.left - reaction.right, greaterThan(60),
        reason: 'and the clock stays at the right, apart from it');
  });
}
