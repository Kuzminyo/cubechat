import 'dart:io';

import 'package:cubechat/features/chats/models/chat.dart';
import 'package:cubechat/features/chats/presentation/widgets/chat_tile.dart';
import 'package:cubechat/features/peers/data/typing_controller.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

/// The row keys off the chat id, which for a direct chat is the peer's pubkey
/// hex — the same canonical id [TypingController] is keyed by. That is the
/// whole reason this works, and the reason a channel cannot accidentally match.
const _peer = 'abc';

Chat _chat({
  bool isDraft = false,
  bool isChannel = false,
  String id = _peer,
}) =>
    Chat(
      id: id,
      peerId: id,
      peerName: 'Kim',
      lastMessage: 'hi',
      lastTime: DateTime(2026, 1, 1),
      unreadCount: 0,
      isMesh: true,
      isOnline: false,
      isDraft: isDraft,
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

/// End any live notice before the test does.
///
/// A notice arms a real timer — that is the point of it, it is what makes the
/// row stop saying "typing…" without being told — and `testWidgets` fails a
/// test whose tree is disposed with a timer still pending. A tearDown is too
/// late: the invariant is checked before those run. Stopping is also exactly
/// what the peer's own stop frame does, so this is not a test-only fiction.
Future<void> _stopTyping(WidgetTester tester, ProviderContainer c) async {
  c.read(typingControllerProvider.notifier).clearAll();
  await tester.pump();
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_typing_');
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
        // Windows holds the files briefly after close; the temp dir is the
        // OS's problem after that.
      }
    }
  });

  testWidgets('the row says who is writing instead of what they last said',
      (tester) async {
    final container = await _pumpTile(tester, _chat());
    expect(find.text('hi'), findsOneWidget);

    container.read(typingControllerProvider.notifier).record(_peer);
    await tester.pump();

    expect(find.text('typing…'), findsOneWidget);
    expect(find.text('hi'), findsNothing);

    await _stopTyping(tester, container);
  });

  testWidgets('it goes away on its own, without a stop frame', (tester) async {
    // The failure this pins is not "typing never shows" but "typing never
    // stops": the map used to change only when a notice or a stop arrived, so
    // a peer who closed the app mid-word left the row saying it forever.
    final container = await _pumpTile(tester, _chat());
    container.read(typingControllerProvider.notifier).record(_peer);
    await tester.pump();
    expect(find.text('typing…'), findsOneWidget);

    await tester.pump(TypingController.ttl + const Duration(seconds: 1));

    expect(find.text('typing…'), findsNothing);
    expect(find.text('hi'), findsOneWidget);
  });

  testWidgets('typing beats a draft, because a draft will keep', (tester) async {
    final container = await _pumpTile(tester, _chat(isDraft: true));
    expect(find.text('Draft: hi'), findsOneWidget);

    container.read(typingControllerProvider.notifier).record(_peer);
    await tester.pump();

    expect(find.text('typing…'), findsOneWidget);
    expect(find.text('Draft: hi'), findsNothing);

    await _stopTyping(tester, container);
  });

  testWidgets('a channel row never claims somebody is typing', (tester) async {
    // Typing is 1:1 on the wire. A channel id could only end up in the map by
    // way of a bug, and showing it would be a promise the protocol does not
    // keep.
    final container = await _pumpTile(
      tester,
      _chat(id: '#ios-team', isChannel: true),
    );
    container.read(typingControllerProvider.notifier).record('#ios-team');
    await tester.pump();

    expect(find.text('typing…'), findsNothing);
    expect(find.text('hi'), findsOneWidget);

    await _stopTyping(tester, container);
  });

  testWidgets('one person writing does not repaint the whole list',
      (tester) async {
    // The row watches `select(m[id])`, so a notice about somebody else is not
    // a rebuild here. Watching the map itself would repaint every row in the
    // list every few seconds for as long as anyone anywhere is typing.
    final container = await _pumpTile(tester, _chat());
    final before = tester.widget<Text>(find.text('hi'));

    container.read(typingControllerProvider.notifier).record('somebody-else');
    await tester.pump();

    expect(identical(tester.widget<Text>(find.text('hi')), before), isTrue);

    await _stopTyping(tester, container);
  });
}
