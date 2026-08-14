import 'dart:io';

import 'package:cubechat/app.dart';
import 'package:cubechat/features/channels/data/channel_controller.dart';
import 'package:cubechat/features/chats/data/pinned_chats_controller.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:cubechat/features/chats/presentation/widgets/chat_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_drag_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('dragging a pinned row by its grip reorders the pinned block',
      (tester) async {
    await tester.pumpWidget(const ProviderScope(child: CubechatApp()));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatsListScreen)));
    final channels = container.read(channelControllerProvider.notifier);
    await channels.join('one');
    await channels.join('two');
    final pins = container.read(pinnedChatsControllerProvider.notifier);
    await pins.pin('#one');
    await pins.pin('#two');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Pinning prepends, so the newest pin is on top.
    expect(container.read(pinnedChatsControllerProvider), ['#two', '#one']);

    // Nothing to drag by until the list is held: a permanently visible grip is
    // a control on every pinned row of a list nobody is rearranging.
    expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);

    await tester.longPress(find.text('#two').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The two bars at the end of the row, not the pin: the pin marks, the grip
    // drags. A pinned row has both, and only the grip starts a reorder.
    final handle = find.byIcon(Icons.drag_handle_rounded).first;
    expect(handle, findsOneWidget);
    final rowHeight = tester.getSize(find.byType(ChatTile).first).height;

    // A plain drag on it starts the reorder, no long press — that gesture
    // belongs to selection.
    final gesture = await tester.startGesture(tester.getCenter(handle));
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(Offset(0, rowHeight / 3));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(container.read(pinnedChatsControllerProvider), ['#one', '#two']);
  });
}
