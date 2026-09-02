import 'package:cubechat/features/chats/models/chat.dart';
import 'package:cubechat/features/chats/presentation/widgets/chat_tile.dart';
import 'package:cubechat/features/peers/data/presence_controller.dart';
import 'package:cubechat/features/peers/presentation/widgets/peer_avatar.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Presence is keyed by canonical id, which for a direct chat is the peer's
/// pubkey hex — the same thing the row's id is. That is what lets a row ask
/// about itself, and what keeps a channel from ever matching.
const _peer = 'abc';
const _somebodyElse = 'def';

Chat _chat({String id = _peer, bool isChannel = false}) => Chat(
      id: id,
      peerId: id,
      peerName: 'Kim',
      lastMessage: 'hi',
      lastTime: DateTime(2026, 1, 1),
      unreadCount: 0,
      isMesh: true,
      isChannel: isChannel,
    );

Future<ProviderContainer> _pumpTile(WidgetTester tester, Chat chat) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ChatTile(chat: chat)),
      ),
    ),
  );
  return container;
}

bool _dotIsLit(WidgetTester tester) =>
    tester.widget<PeerAvatar>(find.byType(PeerAvatar)).online;

/// Drop every beacon before the test ends.
///
/// Recording one arms two real timers — the freshness sweep and the coalescing
/// buffer — and `testWidgets` fails a test whose tree is disposed with a timer
/// still pending. `clear` cancels both, which is also what happens when the
/// app forgets everybody, so this is not a test-only fiction.
void _clearPresence(ProviderContainer c) =>
    c.read(presenceControllerProvider.notifier).clear();

void main() {
  testWidgets('a beacon about this peer lights their row', (tester) async {
    final container = await _pumpTile(tester, _chat());
    expect(_dotIsLit(tester), isFalse);

    container.read(presenceControllerProvider.notifier).record(
          _peer,
          online: true,
        );
    await tester.pump();

    expect(_dotIsLit(tester), isTrue);
    _clearPresence(container);
  });

  testWidgets('a beacon about somebody else leaves the row dark',
      (tester) async {
    // The point of the whole arrangement. Presence used to be a field on the
    // row, computed by `allChatsProvider` off the entire presence map, so a
    // beacon about anybody rebuilt every row in the list — previews, unread
    // counts and the sort included. A row watches one key now, so a stranger's
    // beacon is not an event here at all.
    final container = await _pumpTile(tester, _chat());

    container.read(presenceControllerProvider.notifier).record(
          _somebodyElse,
          online: true,
        );
    await tester.pump();

    expect(_dotIsLit(tester), isFalse);
    expect(container.read(peerOnlineProvider(_peer)), isFalse);
    expect(container.read(peerOnlineProvider(_somebodyElse)), isTrue);
    _clearPresence(container);
  });

  testWidgets('a goodbye beacon puts the dot out', (tester) async {
    final container = await _pumpTile(tester, _chat());
    final presence = container.read(presenceControllerProvider.notifier);

    presence.record(_peer, online: true);
    await tester.pump();
    expect(_dotIsLit(tester), isTrue);

    // Coalescing publishes the first beacon of a burst at once and buffers the
    // rest, so the leaving notice needs the window to elapse before it shows.
    presence.record(_peer, online: false);
    await tester.pump(const Duration(milliseconds: 150));

    expect(_dotIsLit(tester), isFalse);
    _clearPresence(container);
  });

  testWidgets('a channel row never asks about presence', (tester) async {
    // A room is not a person and has no beacon; asking would open a
    // subscription keyed by a channel name, which no beacon can ever match.
    final container = await _pumpTile(
      tester,
      _chat(id: 'general', isChannel: true),
    );

    container.read(presenceControllerProvider.notifier).record(
          'general',
          online: true,
        );
    await tester.pump();

    expect(_dotIsLit(tester), isFalse);
    _clearPresence(container);
  });
}
