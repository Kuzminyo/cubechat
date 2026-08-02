import 'package:cubechat/features/chats/models/chat.dart';
import 'package:cubechat/features/chats/presentation/widgets/chat_tile.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Chat _chat({
  required String name,
  required DateTime at,
  bool online = false,
  int unread = 0,
}) =>
    Chat(
      id: name,
      peerId: name,
      peerName: name,
      lastMessage: 'hello',
      lastTime: at,
      unreadCount: unread,
      isMesh: false,
      isOnline: online,
    );

Future<void> _pumpList(WidgetTester tester, List<Chat> chats) async {
  // A row draws the peer's avatar if we hold one, so the tile now reads from a
  // provider and needs a container even when no picture exists.
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
      home: Scaffold(
        body: Column(
          children: [for (final c in chats) ChatTile(chat: c)],
        ),
      ),
    )),
  );
  await tester.pump();
}

void main() {
  // Midday *today*, not a hardcoded date. formatChatListTime compares against
  // the real clock and only renders a HH:mm time for the current day —
  // anything older comes back as "Yesterday" or a weekday, with no colon for
  // the column-alignment test below to find. Pinned to a calendar date, this
  // suite passed on the day it was written and failed every day after.
  final today = DateTime.now();
  final now = DateTime(today.year, today.month, today.day, 12, 30);

  testWidgets('an offline peer is not labelled, only an online one is marked',
      (tester) async {
    // The dot on the avatar already says who is here, and its absence says the
    // rest. Spelling out "offline" put a grey badge on nearly every row.
    await _pumpList(tester, [
      _chat(name: 'Alice', at: now),
      _chat(name: 'Bob', at: now, online: true),
    ]);
    final t = await AppLocalizations.delegate.load(const Locale('en'));

    expect(find.text(t.chatsStatusOffline), findsNothing);
  });

  testWidgets('timestamps line up in a column regardless of name length',
      (tester) async {
    // They used to trail the name inside its row, so their position moved with
    // whatever preceded them — a long name or an extra pill — and the column
    // came out ragged.
    await _pumpList(tester, [
      _chat(name: 'A', at: now),
      _chat(name: 'A considerably longer display name', at: now, online: true),
      _chat(name: 'Mid length', at: now, unread: 3),
    ]);

    final rights = tester
        .widgetList<Text>(find.textContaining(':'))
        .map((w) => w.data)
        .toList();
    expect(rights, isNotEmpty, reason: 'the rows should render a time');

    final edges = <double>[];
    for (final element in find.byType(ChatTile).evaluate()) {
      final time = find.descendant(
        of: find.byWidget(element.widget),
        matching: find.textContaining(':'),
      );
      edges.add(tester.getBottomRight(time).dx);
    }
    expect(edges, hasLength(3));
    for (final edge in edges) {
      expect(
        edge,
        closeTo(edges.first, 0.5),
        reason: 'every timestamp should end on the same right edge',
      );
    }
  });
}
