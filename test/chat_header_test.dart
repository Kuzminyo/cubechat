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
import 'support/accepted_terms.dart';
import 'support/hive_settle.dart';

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
    // One more, for anything scheduled after the pinned bar's 220 ms growth.
    // (The list no longer waits a frame for the islands — see
    // ChatIslandsLayout — but the extra frame costs nothing.)
    await tester.pump();
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

    await tester.pumpWidget(
      ProviderScope(
        overrides: [acceptedTermsOverride],
        child: const CubechatApp(),
      ),
    );
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

    expect(
      find.byType(AppBar),
      findsNothing,
      reason: 'the header is an island floating over the conversation, not a '
          'bar that owns a band of the screen — an AppBar would put its own '
          'strip of background between the capsule and the chat',
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
    // One control on the bar, and it opens the list of pins. Unpinning lives
    // there now, where the message being unpinned is in front of you.
    expect(find.byTooltip('All pinned messages'), findsOneWidget);

    // The conversation's box is laid out between the islands, on the same
    // frame as they change height (see ChatIslandsLayout) — and it still runs
    // *behind* both of them, because it paints past its own box.
    final listFinder = find.byType(ListView).first;
    final list = tester.widget<ListView>(listFinder);
    expect(
      tester.getTopLeft(listFinder).dy,
      greaterThan(80),
      reason: 'the list must begin under the header capsule and pinned island',
    );
    expect(list.clipBehavior, Clip.none,
        reason: 'the conversation shows through the glass above and below');
    final padding = list.padding as EdgeInsets;
    expect(
      padding.bottom,
      greaterThan(0),
      reason: 'and the newest message still clears the composer',
    );
  });

  testWidgets('search shows total messages and navigates matching results',
      (tester) async {
    final container = await openChat(tester, channel: 'search-room');
    final messages = container.read(messagesControllerProvider.notifier);
    for (var i = 0; i < 3; i++) {
      messages.append(
        '#search-room',
        Message(
          id: 'search-$i',
          chatId: '#search-room',
          text: i == 1 ? 'different' : 'needle $i',
          sentAt: DateTime(2026, 8, 3, 12, i),
          isMine: false,
          wireId: (i + 1).toString() * 32,
        ),
      );
    }
    await beat(tester);

    // The header no longer carries a message count — it answered a question
    // nobody asks mid-conversation and sat where the name wants to be. The
    // total is still reported, inside the search bar, which is where it means
    // something; that is what the "2 / 2" below checks.
    await tester.tap(find.byTooltip('Search'));
    await beat(tester);

    final searchField = find.widgetWithText(TextField, 'Search messages');
    expect(searchField, findsOneWidget);
    await tester.enterText(searchField, 'needle');
    await beat(tester);
    expect(find.text('2 / 2'), findsOneWidget);

    await tester.tap(find.byTooltip('Previous result'));
    await beat(tester);
    expect(find.text('1 / 2'), findsOneWidget);
  });
}
