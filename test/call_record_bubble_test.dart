import 'dart:typed_data';

import 'package:cubechat/features/call/data/call_controller.dart';
import 'package:cubechat/features/call/domain/call_record.dart';
import 'package:cubechat/features/call/domain/call_state_machine.dart';
import 'package:cubechat/features/chat/data/message_selection.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/presentation/widgets/message_bubble.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Dialer extends ChangeNotifier implements CallController {
  final dialed = <String>[];

  @override
  Future<void> dial(String peer) async => dialed.add(peer);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _peer = 'ab' * 32;

Message _record({required bool outgoing, required int seconds}) => Message(
      id: 'call-1',
      chatId: _peer,
      text: encodeCallRecord(
        CallOutcome(
          callId: Uint8List(16),
          outgoing: outgoing,
          talkedFor: Duration(seconds: seconds),
          cause: CallEndCause.hungUp,
          source: CallEndSource.button,
        ),
      ),
      sentAt: DateTime(2026, 9, 15, 18, 5),
      isMine: outgoing,
    );

/// A call in the conversation is something you can call again from, the way
/// Telegram's are — it used to be a line of text.
void main() {
  late _Dialer dialer;
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester, Message message) async {
    dialer = _Dialer();
    container = ProviderContainer(
      overrides: [callControllerProvider.overrideWith((ref) => dialer)],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
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
            body: Center(child: MessageBubble(message: message, chatId: _peer)),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// The providers behind a bubble keep timers of their own (conversation
  /// settings sweeps mutes once a minute), so the container goes down inside
  /// the test, where the pending-timer check runs.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('says which way it went and for how long, and calls back',
      (tester) async {
    await pump(tester, _record(outgoing: true, seconds: 65));
    expect(find.text('Outgoing call'), findsOneWidget);
    expect(find.text('1:05'), findsOneWidget);

    await tester.tap(find.text('Outgoing call'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(dialer.dialed, [_peer]);
    await finish(tester);
  });

  testWidgets('a missed call says so', (tester) async {
    await pump(tester, _record(outgoing: false, seconds: 0));
    expect(find.text('Missed call'), findsOneWidget);
    expect(find.byIcon(Icons.call_missed_rounded), findsOneWidget);
    expect(find.textContaining('cubechat:call'), findsNothing);
    await finish(tester);
  });

  testWidgets('while picking messages out, a tap ticks instead of calling',
      (tester) async {
    await pump(tester, _record(outgoing: false, seconds: 12));
    container.read(messageSelectionProvider(_peer).notifier).toggle('other');
    await tester.pump();

    await tester.tap(find.text('Incoming call'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(dialer.dialed, isEmpty);
    expect(container.read(messageSelectionProvider(_peer)), contains('call-1'));
    await finish(tester);
  });
}
