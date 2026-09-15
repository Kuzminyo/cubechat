import 'dart:io';

import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/core/theme/colors.dart';
import 'package:cubechat/features/chats/data/chat_selection_controller.dart';
import 'package:cubechat/features/chats/data/swipe_action_controller.dart';
import 'package:cubechat/features/chats/models/chat.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:cubechat/features/chats/presentation/widgets/chat_tile.dart';
import 'package:cubechat/features/chats/presentation/widgets/swipe_action_row.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// What the chat list rebuilds when one conversation changes.
///
/// Build 1054 measured the list catching up after a conversation closed: one
/// frame of 19-27 ms on the UI thread, right as the slide back ended. Nothing
/// on screen had changed but the row of the chat just read, and every visible
/// row was built again anyway, because every list rebuild made a new widget for
/// every row. A row whose chat, position and mode are all as they were comes
/// back as the same widget now, and Flutter skips it.
final _rows = StateProvider<List<Chat>>((_) => [
      for (var i = 0; i < 20; i++)
        Chat(
          id: '${'a' * 62}${i.toString().padLeft(2, '0')}',
          peerId: '${'a' * 62}${i.toString().padLeft(2, '0')}',
          peerName: 'Person $i',
          lastMessage: 'message $i',
          lastTime: DateTime(2026, 9, 15, 12, 60 - i),
          unreadCount: 0,
          isMesh: false,
        ),
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await hiveCipherProvider.wipe();
    tempDir = await Directory.systemTemp.createTemp('cubechat_list_rebuild_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    await hiveCipherProvider.wipe();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the Hive files briefly after close.
    }
  });

  testWidgets('a message in one chat rebuilds that row, not the list',
      (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        visibleChatsProvider.overrideWith((ref) => ref.watch(_rows)),
      ],
    );
    addTearDown(container.dispose);

    final counts = <String, int>{};
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      final name = element.widget.runtimeType.toString();
      counts[name] = (counts[name] ?? 0) + 1;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark(useMaterial3: true),
          home: ColoredBox(
            color: AppColors.bgDeep,
            child: const ChatsListScreen(),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    final visible = counts['ChatTile'] ?? 0;
    expect(visible, greaterThan(4), reason: 'the list drew its rows');
    counts.clear();

    // The top row gets a new preview; its time does not move, so the order
    // stays as it was and no other row has anything new to show.
    final before = container.read(_rows);
    final top = before.first;
    container.read(_rows.notifier).state = [
      Chat(
        id: top.id,
        peerId: top.peerId,
        peerName: top.peerName,
        lastMessage: 'something new',
        lastTime: top.lastTime,
        unreadCount: 1,
        isMesh: false,
      ),
      ...before.skip(1),
    ];
    await tester.pump();

    final total = counts.values.fold<int>(0, (a, b) => a + b);
    // ignore: avoid_print
    print('visible rows $visible; after one change: total $total $counts');
    expect(counts['ChatTile'] ?? 0, 1,
        reason: 'only the row whose chat changed');
    expect(counts['SwipeActionRow'] ?? 0, lessThanOrEqualTo(1));
    // 727 before the rows were kept; 211 after, of which 78 are the six
    // wrappers the reorderable list puts round each of its 13 rows.
    expect(total, lessThanOrEqualTo(260));
    expect(find.text('something new'), findsOneWidget);

    // Picking a chat out changes what every row does, and every row has to
    // hear about it: a kept row must not keep the mode it was built in.
    container.read(chatSelectionProvider.notifier).toggle(top.id);
    await tester.pump(const Duration(milliseconds: 400));
    final tiles = tester.widgetList<ChatTile>(find.byType(ChatTile)).toList();
    expect(tiles.where((t) => t.selected).map((t) => t.chat.id), [top.id]);
    expect(
      tester
          .widgetList<SwipeActionRow>(find.byType(SwipeActionRow))
          .every((r) => r.action == ChatSwipeAction.none),
      isTrue,
      reason: 'no swiping while picking',
    );

    container.read(chatSelectionProvider.notifier).clear();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.widgetList<ChatTile>(find.byType(ChatTile)).any((t) => t.selected),
      isFalse,
    );
  });
}
