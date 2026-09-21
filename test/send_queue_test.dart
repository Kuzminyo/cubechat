import 'dart:typed_data';

import 'package:cubechat/core/transport/store_forward_cache.dart';
import 'package:cubechat/features/chat/data/send_queue.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/presentation/widgets/send_queue_sheet.dart';
import 'package:cubechat/features/chats/data/saved_messages.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// "Always visible whether a message is still waiting for a connection or
/// already delivered" — the first part of the bad-connection mode.
void main() {
  final alice = 'aa' * 32;
  final bob = 'bb' * 32;

  Message mine(
    String id, {
    MessageStatus status = MessageStatus.sending,
    MessageRoute? route = MessageRoute.queued,
    bool isMine = true,
    int minute = 0,
    String? chatId,
  }) =>
      Message(
        id: id,
        chatId: chatId ?? alice,
        text: 'note $id',
        sentAt: DateTime(2026, 9, 21, 12, minute),
        isMine: isMine,
        status: status,
        route: route,
        wireId: id.padRight(32, '0'),
      );

  group('what is waiting', () {
    test('only ours, still sending, and filed as having found no road', () {
      final queue = queuedMessages({
        alice: [
          mine('q1', minute: 3),
          mine('inflight', route: MessageRoute.internet),
          mine('delivered', status: MessageStatus.delivered),
          mine('theirs', isMine: false),
        ],
        bob: [mine('q2', minute: 1, chatId: bob)],
      });
      expect(queue.map((q) => q.message.id), ['q2', 'q1'],
          reason: 'oldest first, across conversations',);
      expect(queue.first.chatId, bob);
    });

    test('one message filed under two keys is one message waiting', () {
      final queued = mine('same');
      expect(
        queuedMessages({
          alice: [queued],
          'legacy-address': [queued],
        }),
        hasLength(1),
      );
    });

    test('the notebook never waits for anybody', () {
      expect(
        queuedMessages({
          savedChatId: [mine('note', chatId: savedChatId)],
        }),
        isEmpty,
      );
    });
  });

  group('taking one back', () {
    Uint8List bytes(int n) => Uint8List.fromList(List<int>.filled(n, 7));

    test('the held frame goes, wherever it was filed', () {
      final store = StoreForwardCache();
      final msgId = Uint8List.fromList(List<int>.generate(16, (i) => i));
      final hex = msgId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      // The same frame under two routing ids, as across an epoch boundary.
      for (final dest in [bytes(8), Uint8List.fromList(List.filled(8, 9))]) {
        store.store(
          destHash: dest,
          frameBytes: bytes(40),
          origin: bytes(8),
          msgId: msgId,
        );
      }
      store.store(
        destHash: bytes(8),
        frameBytes: bytes(40),
        origin: bytes(8),
        msgId: Uint8List.fromList(List<int>.filled(16, 0xAB)),
      );
      expect(store.size, 3);

      expect(store.discardMsgId(hex), isTrue);
      expect(store.size, 1, reason: 'someone else\'s frame is not touched');
      expect(store.discardMsgId(hex), isFalse,
          reason: 'already gone: the cancel says it was too late',);
    });
  });

  group('the entry and the sheet', () {
    Future<void> pump(WidgetTester tester, List<QueuedMessage> queue) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sendQueueProvider.overrideWithValue(queue)],
          child: const MaterialApp(
            locale: Locale('en'),
            localizationsDelegates: [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: SendQueueEntry()),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('nothing at all while nothing waits', (tester) async {
      await pump(tester, const []);
      expect(find.byType(SendQueueEntry), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off_rounded), findsNothing);
    });

    testWidgets('says how many, and opens what they are', (tester) async {
      await pump(tester, [
        QueuedMessage(chatId: alice, message: mine('q1')),
        QueuedMessage(chatId: '#room', message: mine('q2', chatId: '#room')),
      ]);
      expect(find.text('2 messages waiting for a connection'), findsOneWidget);

      await tester.tap(find.text('2 messages waiting for a connection'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Waiting to send'), findsOneWidget);
      expect(find.text('#room'), findsOneWidget);
      expect(find.textContaining('note q1'), findsOneWidget);
      expect(find.byTooltip('Cancel sending'), findsNWidgets(2));
      expect(find.text('Try now'), findsOneWidget);
    });
  });
}
