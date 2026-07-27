import 'dart:io';

import 'package:cubechat/app.dart';
import 'package:cubechat/features/channels/data/channel_controller.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/data/pinned_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/hive_settle.dart';

/// Drives the real chat screen: pin a message from the long-press menu, see the
/// bar appear, unpin it again. A channel is the cheapest conversation to stand
/// up in a test — membership is just holding the key, so no handshake, no peer
/// roster, and the pin path is the same one a 1:1 chat uses.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_pin_ui_');
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

  /// Let the app settle without pumpAndSettle — the aurora animates forever, so
  /// the tree never reaches a settled state.
  Future<void> beat(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Opens the channel with one message already pinned, for tests about what
  /// happens *after* pinning rather than about the pin gesture itself.
  Future<ProviderContainer> openPinnedChat(WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: CubechatApp()));
    await tester.pump(const Duration(milliseconds: 50));
    await beat(tester);

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatsListScreen)));
    await container.read(channelControllerProvider.notifier).join('test');
    container.read(messagesControllerProvider.notifier).append(
          '#test',
          Message(
            id: 'm1',
            chatId: '#test',
            text: 'адреса зустрічі',
            sentAt: DateTime(2026, 7, 26, 16, 8),
            isMine: false,
            wireId: 'aa' * 16,
          ),
        );
    await container.read(pinnedControllerProvider.notifier).pin('#test', 'aa' * 16);
    await beat(tester);

    await tester.tap(find.text('#test').first);
    await beat(tester);
    return container;
  }

  testWidgets('pinning from the long-press menu shows the pinned bar',
      (tester) async {
    await tester.pumpWidget(const ProviderScope(child: CubechatApp()));
    await tester.pump(const Duration(milliseconds: 50));
    await beat(tester);

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatsListScreen)));
    await container.read(channelControllerProvider.notifier).join('test');
    await beat(tester);

    // A message to pin, in the channel's bucket.
    container.read(messagesControllerProvider.notifier).append(
          '#test',
          Message(
            id: 'm1',
            chatId: '#test',
            text: 'адреса зустрічі',
            sentAt: DateTime(2026, 7, 26, 16, 8),
            isMine: false,
            wireId: 'aa' * 16,
          ),
        );
    await beat(tester);

    // Open the chat.
    await tester.tap(find.text('#test').first);
    await beat(tester);
    expect(find.text('адреса зустрічі'), findsOneWidget);

    await tester.longPress(find.text('адреса зустрічі'));
    await beat(tester);

    // The details header is part of the same menu — the read time lives here.
    expect(find.textContaining('Sent'), findsOneWidget);

    await tester.tap(find.text('Pin'));
    await beat(tester);

    expect(
      container.read(pinnedControllerProvider)['#test']?.wireId,
      'aa' * 16,
    );
    // The bar names the pinned message and previews it.
    expect(find.text('Pinned message'), findsOneWidget);

    // Unpinning asks first. The pin is shared state — clearing it takes the
    // banner away from everyone in the chat — and the button sits right next to
    // one you tap to jump to the message.
    await tester.tap(find.byTooltip('Unpin'));
    await beat(tester);
    expect(find.text('Unpin this message?'), findsOneWidget);
    expect(
      container.read(pinnedControllerProvider)['#test'],
      isNotNull,
      reason: 'nothing happens until the confirmation is answered',
    );

    await tester.tap(find.widgetWithText(TextButton, 'Unpin'));
    await beat(tester);
    expect(container.read(pinnedControllerProvider)['#test'], isNull);
    expect(find.text('Pinned message'), findsNothing);
  });

  testWidgets('cancelling the unpin leaves the message pinned', (tester) async {
    final container = await openPinnedChat(tester);

    await tester.tap(find.byTooltip('Unpin'));
    await beat(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await beat(tester);

    expect(container.read(pinnedControllerProvider)['#test']?.wireId, 'aa' * 16);
    expect(find.text('Pinned message'), findsOneWidget);
  });
}
