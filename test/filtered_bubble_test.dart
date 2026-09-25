import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/presentation/widgets/message_bubble.dart';
import 'package:cubechat/features/moderation/data/filter_settings.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A5 on screen: a rude line from somebody you have not written to, or in a
/// channel, folds to "Hidden by the filter · Show"; your own messages, a
/// conversation you take part in, and a switched-off filter do not fold.

const _rude = 'shit happens';
final _peer = 'c' * 64;

Message _msg(String chatId, {bool mine = false, String text = _rude}) =>
    Message(
      id: 'm-$mine-$text',
      chatId: chatId,
      text: text,
      sentAt: DateTime(2026, 9, 25, 10, 11),
      isMine: mine,
    );

class _Messages extends MessagesController {
  _Messages(this._history);

  final Map<String, List<Message>> _history;

  @override
  Map<String, List<Message>> build() => _history;
}

class _Filter extends FilterSettings {
  _Filter(this._on);

  final bool _on;

  @override
  bool build() => _on;
}

Future<void> _pump(
  WidgetTester tester,
  Message message, {
  List<Message> history = const [],
  bool filterOn = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        messagesControllerProvider.overrideWith(
          () => _Messages({
            message.chatId: [...history, message],
          }),
        ),
        filterEnabledProvider.overrideWith(() => _Filter(filterOn)),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MessageBubble(message: message, chatId: message.chatId),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a stranger\'s rude line folds, and Show opens it',
      (tester) async {
    await _pump(tester, _msg(_peer));
    expect(find.text('Hidden by the filter'), findsOneWidget);
    expect(find.text(_rude), findsNothing);

    await tester.tap(find.text('Show'));
    await tester.pump();
    expect(find.text('Hidden by the filter'), findsNothing);
    expect(find.text(_rude), findsOneWidget);
  });

  testWidgets('in a conversation you have written in, it does not fold',
      (tester) async {
    await _pump(
      tester,
      _msg(_peer),
      history: [_msg(_peer, mine: true, text: 'hi')],
    );
    expect(find.text('Hidden by the filter'), findsNothing);
    expect(find.text(_rude), findsOneWidget);
  });

  testWidgets('in a channel it folds even if you have posted there',
      (tester) async {
    await _pump(
      tester,
      _msg('#room'),
      history: [_msg('#room', mine: true, text: 'hi')],
    );
    expect(find.text('Hidden by the filter'), findsOneWidget);
  });

  testWidgets('switched off, nothing folds', (tester) async {
    await _pump(tester, _msg(_peer), filterOn: false);
    expect(find.text('Hidden by the filter'), findsNothing);
    expect(find.text(_rude), findsOneWidget);
  });

  testWidgets('your own message never folds', (tester) async {
    await _pump(tester, _msg(_peer, mine: true));
    expect(find.text('Hidden by the filter'), findsNothing);
  });
}
