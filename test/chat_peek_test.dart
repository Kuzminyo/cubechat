import 'dart:io';

import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chats/data/read_markers_controller.dart';
import 'package:cubechat/features/chats/models/chat.dart';
import 'package:cubechat/features/chats/presentation/chat_peek.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

const _chatId = 'abcdef';

Message _incoming(String text, DateTime at) => Message(
      id: '$text-id',
      chatId: _chatId,
      text: text,
      sentAt: at,
      isMine: false,
    );

/// Relative to now, not a fixed pair of dates.
///
/// The day separators are the point of one of these tests, and "Yesterday" is
/// a fact about the day the test runs. Written as 2026-08-30 and 2026-08-31 it
/// passed on the afternoon it was written and would have gone red the next
/// morning, in a file nobody had touched.
final _yesterday = DateTime.now().subtract(const Duration(days: 1));
final _today = DateTime.now();

class _FakeMessages extends MessagesController {
  @override
  Map<String, List<Message>> build() => {
        _chatId: [
          _incoming('older', _yesterday),
          _incoming('newer', _today),
        ],
      };
}

Chat _chat() => Chat(
      id: _chatId,
      peerId: _chatId,
      peerName: 'Kim',
      lastMessage: 'newer',
      lastTime: _today,
      unreadCount: 2,
      isMesh: true,
      isOnline: false,
    );

/// The scope is owned by the widget tree, not held outside it.
///
/// An external `ProviderContainer` outlives the tree, and
/// `ConversationSettingsController` — which a bubble reads — keeps a one-minute
/// prune timer cancelled in `ref.onDispose`. Disposed after the tree, that
/// timer is still pending when `testWidgets` checks, and every test here failed
/// on it. Nothing was wrong with the peek: in the app the container lives as
/// long as the process, which is exactly what a periodic sweep wants.
Future<ProviderContainer> _openPeek(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [messagesControllerProvider.overrideWith(_FakeMessages.new)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showChatPeek(
                  context,
                  _chat(),
                  onOpen: () {},
                  onDelete: () {},
                ),
                child: const Text('peek'),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('peek'));
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_peek_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows holds the files briefly after close.
      }
    }
  });

  testWidgets('looking does not mark the conversation read', (tester) async {
    // The whole point of the screen. If this ever goes green by accident —
    // someone routes the peek through ChatScreen, say — the feature is gone
    // while still looking like it works.
    final container = await _openPeek(tester);

    expect(
      container.read(readMarkersControllerProvider).containsKey(_chatId),
      isFalse,
    );
  });

  testWidgets('the conversation is there to scroll', (tester) async {
    await _openPeek(tester);

    expect(find.text('newer'), findsOneWidget);
    expect(find.text('older'), findsOneWidget);
  });

  testWidgets('messages are separated by day', (tester) async {
    // Two messages a day apart, so exactly two separators — the peek reuses
    // `startsNewDay`/`formatDayHeader` rather than growing its own idea of
    // when a day begins.
    await _openPeek(tester);

    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
  });

  testWidgets('the bubbles cannot be touched', (tester) async {
    // A peek looks. Reacting, opening media, and above all spending a
    // view-once photo are all things a glance must not do, and the guarantee
    // is structural rather than per-widget.
    await _openPeek(tester);

    expect(
      find.ancestor(
        of: find.text('newer'),
        matching: find.byType(IgnorePointer),
      ),
      findsWidgets,
    );
  });

  testWidgets('tapping the conversation closes it', (tester) async {
    // What was reported as "you cannot get back": the barrier behind
    // everything did close the peek, and the message list covered the whole
    // middle of the screen. The bubbles ignore pointers, but the scrollable
    // under them does not pass a tap through, so the only places that worked
    // were the margins — and nothing said so.
    await _openPeek(tester);
    expect(find.text('newer'), findsOneWidget);

    await tester.tap(find.text('newer'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.text('newer'), findsNothing);
  });

  testWidgets('the list still scrolls rather than closing', (tester) async {
    // The other half of the same change: a tap closes, a drag must not. If
    // the dismissal ever becomes a drag handler, this is what catches it.
    await _openPeek(tester);

    // At the list, not at a bubble: bubbles ignore pointers on purpose, and a
    // drag that lands on one proves nothing about whether the list scrolls.
    await tester.drag(find.byType(ListView), const Offset(0, 60));
    await tester.pumpAndSettle();

    expect(find.text('newer'), findsOneWidget);
  });

  testWidgets('tapping outside closes it', (tester) async {
    await _openPeek(tester);
    expect(find.text('newer'), findsOneWidget);

    // Top-left corner: above the header island, over the barrier.
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    expect(find.text('newer'), findsNothing);
  });
}
