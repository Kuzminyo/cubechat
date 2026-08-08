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

  // Reported from the field: with more than two pins, the first tap jumps
  // correctly and every tap after it goes back to the first one again. The bar
  // is meant to walk upward through the stack, one pin per tap.
  testWidgets('the bar walks through every pin instead of sticking on one',
      (tester) async {
    await tester.pumpWidget(const ProviderScope(child: CubechatApp()));
    await tester.pump(const Duration(milliseconds: 50));
    await beat(tester);

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatsListScreen)));
    await container.read(channelControllerProvider.notifier).join('test');

    // Oldest first, which is how the store holds them.
    const bodies = ['перший', 'другий', 'третій'];
    const ids = ['aa', 'bb', 'cc'];
    final messages = container.read(messagesControllerProvider.notifier);
    for (var i = 0; i < bodies.length; i++) {
      messages.append(
        '#test',
        Message(
          id: 'm$i',
          chatId: '#test',
          text: bodies[i],
          sentAt: DateTime(2026, 7, 26, 16, i),
          isMine: false,
          wireId: ids[i] * 16,
        ),
      );
    }
    final pins = container.read(pinnedControllerProvider.notifier);
    for (var i = 0; i < bodies.length; i++) {
      await pins.pin('#test', ids[i] * 16);
    }
    await beat(tester);

    await tester.tap(find.text('#test').first);
    await beat(tester);

    expect(find.text('третій'), findsWidgets, reason: 'chat should be open');
    expect(container.read(pinnedControllerProvider.notifier)
        .pinnedAllIn('#test').length, 3, reason: 'three pins recorded');

    // The bar opens on the newest pin — the one nearest what you are reading —
    // and counts down as it walks upward through the stack.
    expect(find.text('Pinned message 3/3'), findsOneWidget);

    // Tapping the bar is the whole interaction: it jumps to what it is showing
    // and then points at the one above.
    Finder bar() => find.textContaining('Pinned message');

    await tester.tap(bar());
    await beat(tester);
    expect(find.text('Pinned message 2/3'), findsOneWidget,
        reason: 'the second tap must be offering the middle pin');

    await tester.tap(bar());
    await beat(tester);
    expect(find.text('Pinned message 1/3'), findsOneWidget,
        reason: 'the third tap must be offering the oldest pin');

    // …and wraps back to the newest rather than stopping.
    await tester.tap(bar());
    await beat(tester);
    expect(find.text('Pinned message 3/3'), findsOneWidget);
  });

  // The other half of what the bar has to do: actually travel. A long history
  // is essential — with three messages on screen there is nothing to scroll and
  // the walk never runs.
  //
  // This does not reproduce the "always goes back to the first pin" report; it
  // passes with and without the `_builtFrom`/`_builtTo` reset that report led
  // to. It is here because the walk is fiddly, easy to break silently, and had
  // nothing covering it at all.
  testWidgets('walking the pins actually scrolls to each one', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: CubechatApp()));
    await tester.pump(const Duration(milliseconds: 50));
    await beat(tester);

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatsListScreen)));
    await container.read(channelControllerProvider.notifier).join('test');

    final messages = container.read(messagesControllerProvider.notifier);
    for (var i = 0; i < 60; i++) {
      messages.append(
        '#test',
        Message(
          id: 'm$i',
          chatId: '#test',
          text: 'рядок $i',
          sentAt: DateTime(2026, 7, 26, 16, 0).add(Duration(minutes: i)),
          isMine: false,
          wireId: i.toRadixString(16).padLeft(2, '0') * 16,
        ),
      );
    }
    // Spread far enough apart that reaching one means leaving the others.
    final pins = container.read(pinnedControllerProvider.notifier);
    for (final i in [2, 30, 57]) {
      await pins.pin('#test', i.toRadixString(16).padLeft(2, '0') * 16);
    }
    await beat(tester);

    await tester.tap(find.text('#test').first);
    await beat(tester);

    // Read back through the history and return. This is the step that matters:
    // the span of laid-out rows only ever widened, so browsing was enough to
    // leave it covering most of the conversation — and every later jump then
    // decided its target was already built and waited instead of moving.
    await tester.drag(find.byType(ListView), const Offset(0, 2000));
    await beat(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await beat(tester);

    Future<void> tapBar() async {
      await tester.tap(find.textContaining('Pinned message'));
      // The jump walks frame by frame — up to 48 of them — and then eases in
      // over 380 ms, so this has to pump well past both.
      for (var i = 0; i < 70; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
    }

    // Newest pin first.
    expect(find.text('Pinned message 3/3'), findsOneWidget);
    await tapBar();
    expect(find.text('рядок 57'), findsWidgets,
        reason: 'the first tap should land on the newest pin');

    await tapBar();
    expect(find.text('рядок 30'), findsWidgets,
        reason: 'the second tap must actually travel to the middle pin');

    await tapBar();
    expect(find.text('рядок 2'), findsWidgets,
        reason: 'the third tap must travel to the oldest pin');
  });
}
