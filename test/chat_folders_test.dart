import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/app.dart';
import 'package:cubechat/features/channels/data/channel_controller.dart';
import 'package:cubechat/features/chats/data/chat_folders_controller.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:cubechat/features/contacts/presentation/contacts_screen.dart';
import 'package:cubechat/features/peers/data/known_peers_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

/// Folders, and the row that only exists once there are some.
///
/// The list used to ship with four filter pills whether or not anyone wanted
/// them — a permanent strip of chrome between the search field and the first
/// conversation, on the screen that opens the app. They are opt-in now, which
/// means the default state has to be genuinely nothing.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_folders_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the Hive files briefly after close.
    }
  });

  Future<void> beat(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// A phone-sized app with one peer and one channel in the list.
  Future<ProviderContainer> openChats(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: CubechatApp()));
    await tester.pump(const Duration(milliseconds: 50));
    await beat(tester);

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatsListScreen)));
    container.read(knownPeersControllerProvider.notifier).upsert(
          pubkeyHex: 'ab' * 32,
          displayName: 'Alice',
          signPublicKey: Uint8List(32),
        );
    await container.read(channelControllerProvider.notifier).join('kvartira');
    await beat(tester);
    return container;
  }

  testWidgets('a fresh install has no folder row at all', (tester) async {
    await openChats(tester);

    expect(find.text('All'), findsNothing);
    expect(find.text('Unread'), findsNothing);
    expect(find.text('Favorites'), findsNothing);
    // The chats themselves are of course still there.
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('#kvartira'), findsOneWidget);
  });

  testWidgets('a folder switched on appears as a pill and cuts the list',
      (tester) async {
    final container = await openChats(tester);

    await container
        .read(chatFoldersControllerProvider.notifier)
        .toggle(ChatFolder.channels);
    await beat(tester);

    // "All" arrives with the row: without a way back, a folder would be a trap.
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Channels'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);

    await tester.tap(find.text('Channels'));
    await beat(tester);

    expect(find.text('#kvartira'), findsOneWidget);
    expect(find.text('Alice'), findsNothing);

    await tester.tap(find.text('All'));
    await beat(tester);
    expect(find.text('Alice'), findsOneWidget);
  });

  testWidgets('switching a folder off releases the list it was filtering',
      (tester) async {
    final container = await openChats(tester);
    final folders = container.read(chatFoldersControllerProvider.notifier);

    await folders.toggle(ChatFolder.channels);
    await beat(tester);
    await tester.tap(find.text('Channels'));
    await beat(tester);
    expect(find.text('Alice'), findsNothing);

    await folders.toggle(ChatFolder.channels);
    await beat(tester);

    expect(
      find.text('Alice'),
      findsOneWidget,
      reason: 'a filter with no pill left on screen is chats that vanished',
    );
    expect(find.text('All'), findsNothing);
  });

  testWidgets('the next tab follows the finger and settles under it',
      (tester) async {
    await openChats(tester);
    expect(find.byType(ChatsListScreen), findsOneWidget);
    expect(find.byType(ContactsScreen), findsNothing,
        reason: 'a tab nobody is looking at is parked, not drawn');

    // Dragging, not flicking: the point of the strip is that the neighbour is
    // on screen *while the finger is down*, at the distance the finger put it.
    // Several small moves, the way a finger reports: the first one only
    // crosses the slop and starts the drag, so a single big jump would be a
    // gesture that never updates.
    final gesture = await tester.startGesture(const Offset(200, 400));
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();
    }

    expect(find.byType(ChatsListScreen), findsOneWidget);
    expect(
      find.byType(ContactsScreen),
      findsOneWidget,
      reason: 'both are on screen mid-drag, which is what makes it a strip '
          'rather than a transition between two states',
    );

    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byType(ContactsScreen), findsOneWidget);
    expect(find.byType(ChatsListScreen), findsNothing,
        reason: 'and the one left behind parks again');
  });

  testWidgets('a flick sideways decides on its own, and comes back',
      (tester) async {
    await openChats(tester);

    // Short and fast: not far enough to cross the halfway line, fast enough
    // that the finger has already said where it is going.
    await tester.timedDrag(
      find.byType(ChatsListScreen),
      const Offset(-60, 0),
      const Duration(milliseconds: 40),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ContactsScreen), findsOneWidget);

    await tester.timedDrag(
      find.byType(ContactsScreen),
      const Offset(60, 0),
      const Duration(milliseconds: 40),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChatsListScreen), findsOneWidget);
  });
}
