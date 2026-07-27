import 'dart:io';

import 'package:cubechat/app.dart';
import 'package:cubechat/features/chat/presentation/widgets/chat_input.dart';
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

/// The chat header is one floating capsule with circular edge controls and a
/// pinned island under it. What can go wrong without anyone noticing is **fit**:
/// the identity area has to give way to the action icons on a narrow phone
/// rather than overflow, and a widget test fails on an overflow by itself, so
/// these run at a real phone width instead of the 800x600 default.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_header_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
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

  /// Opens a channel chat on a 360x780 phone. A channel is the cheapest
  /// conversation to stand up — no handshake, no roster — and the header widget
  /// is the same one a 1:1 chat builds.
  Future<ProviderContainer> openChat(
    WidgetTester tester, {
    required String channel,
  }) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: CubechatApp()));
    await tester.pump(const Duration(milliseconds: 50));
    await beat(tester);

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatsListScreen)));
    await container.read(channelControllerProvider.notifier).join(channel);
    await beat(tester);

    await tester.tap(find.text('#$channel').first);
    await beat(tester);
    return container;
  }

  testWidgets('header capsule fits a narrow phone', (tester) async {
    // The longest name a channel can carry (the invite frame caps it), so the
    // identity area is under the most pressure it will ever see.
    await openChat(tester, channel: 'kvartira-longest');

    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(
      appBar.forceMaterialTransparency,
      isTrue,
      reason: 'the floating capsule must not sit on a full-width AppBar fill',
    );

    // Back button, name, and the channel's presence line.
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.text('#kvartira-longest'), findsWidgets);
    expect(find.text('Group channel · shared key'), findsOneWidget);
    // Header and composer now render through the exact same surface widget.
    expect(
      find.byType(MessageIslandGlass),
      findsNWidgets(2),
      reason: 'header and composer must share the SMS-island texture',
    );
    expect(
      find.byKey(const ValueKey('chat-header-message-island')),
      findsOneWidget,
    );
  });

  testWidgets('the pinned island sits under the header with a preview',
      (tester) async {
    final container = await openChat(tester, channel: 'kvartira');

    container.read(messagesControllerProvider.notifier).append(
          '#kvartira',
          Message(
            id: 'm1',
            chatId: '#kvartira',
            text: 'вул. Сагайдачного 12, код 4507',
            sentAt: DateTime(2026, 7, 26, 18, 18),
            isMine: false,
            wireId: 'aa' * 16,
          ),
        );
    await container
        .read(pinnedControllerProvider.notifier)
        .pin('#kvartira', 'aa' * 16);
    await beat(tester);

    expect(find.text('Pinned message'), findsOneWidget);
    // The island previews the pinned line itself — one copy in the bubble, one
    // in the island.
    expect(find.text('вул. Сагайдачного 12, код 4507'), findsNWidgets(2));
    expect(find.byTooltip('Unpin'), findsOneWidget);
  });
}
