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
    expect(
      find.byIcon(Icons.add_rounded),
      findsNothing,
      reason:
          'folder management stays in the overflow menu, not inside the island',
    );

    await tester.tap(find.text('Channels'));
    await beat(tester);

    expect(find.text('#kvartira'), findsOneWidget);
    expect(find.text('Alice'), findsNothing);

    await tester.tap(find.text('All'));
    await beat(tester);
    expect(find.text('Alice'), findsOneWidget);
  });

  testWidgets('the title stays put while the search collapses into it',
      (tester) async {
    final container = await openChats(tester);
    final peers = container.read(knownPeersControllerProvider.notifier);
    for (var i = 0; i < 12; i++) {
      final byte = (i + 1).toRadixString(16).padLeft(2, '0');
      peers.upsert(
        pubkeyHex: List.filled(32, byte).join(),
        displayName: 'Friend $i',
        signPublicKey: Uint8List(32),
      );
    }
    await beat(tester);

    await container
        .read(chatFoldersControllerProvider.notifier)
        .toggle(ChatFolder.channels);
    await beat(tester);

    final header = find.byKey(const ValueKey('chats-top-layer'));
    final searchIcon = find.byKey(const ValueKey('chats-header-search-button'));
    final folder = find.byKey(const ValueKey('chats-folder-island'));
    final scroll = find.byKey(const ValueKey('chats-scroll-layer'));

    expect(header, findsOneWidget);
    expect(searchIcon, findsOneWidget);
    expect(folder, findsOneWidget);
    expect(find.text('CubeChat'), findsOneWidget);

    // At rest the search is a field: full width, with its hint showing.
    final restWidth = tester.getSize(find.ancestor(
      of: searchIcon,
      matching: find.byType(InkWell),
    ).first).width;
    expect(restWidth, greaterThan(200));
    expect(find.text('Search chats…'), findsOneWidget);

    final headerTop = tester.getTopLeft(header).dy;

    await tester.drag(scroll, const Offset(0, -120));
    await beat(tester);

    // The title layer has not moved, and the folder island is pinned directly
    // under it rather than scrolling away with the rows.
    expect(tester.getTopLeft(header).dy, headerTop);
    expect(
      tester.getTopLeft(folder).dy,
      closeTo(tester.getBottomLeft(header).dy, 1),
      reason: 'the folder island pins under the title layer',
    );

    // And the field has become a button: same widget, a fraction of the width,
    // with the hint gone.
    final collapsedWidth = tester.getSize(find.ancestor(
      of: searchIcon,
      matching: find.byType(InkWell),
    ).first).width;
    expect(collapsedWidth, lessThan(60));
    expect(searchIcon.hitTestable(), findsOneWidget);
    expect(find.text('Search chats…'), findsNothing);
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
    expect(
      find.byType(ContactsScreen),
      findsNothing,
      reason: 'a tab nobody is looking at is parked, not drawn',
    );

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
    expect(
      find.byType(ChatsListScreen),
      findsNothing,
      reason: 'and the one left behind parks again',
    );
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
