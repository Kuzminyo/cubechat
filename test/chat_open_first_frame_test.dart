import 'dart:io';

import 'package:cubechat/app.dart';
import 'package:cubechat/features/channels/data/channel_controller.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/presentation/widgets/message_bubble.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/accepted_terms.dart';
import 'support/hive_settle.dart';

/// Opening a chat builds what is on screen in its first frame, and the rest
/// once it has arrived.
///
/// 1173 on the S24+ (2026-10-16): 12 bubbles in that frame at ~1 ms each,
/// where the screen shows 8 or 9 — the others were the list's cache, built in
/// the one frame the open is waiting on.
void main() {
  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_open_frame_');
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

  Future<void> settle(WidgetTester tester, [int frames = 20]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('the first frame of a chat builds only what can be seen',
      (tester) async {
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
    await settle(tester, 10);
    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatsListScreen)));
    await container.read(channelControllerProvider.notifier).join('room');
    final messages = container.read(messagesControllerProvider.notifier);
    for (var i = 0; i < 40; i++) {
      messages.append(
        '#room',
        Message(
          id: 'm$i',
          chatId: '#room',
          text: 'message $i',
          sentAt: DateTime(2026, 10, 15, 12, i),
          isMine: i.isEven,
          wireId: i.toRadixString(16).padLeft(32, '0'),
        ),
      );
    }
    await settle(tester, 10);

    await tester.tap(find.text('#room').first);
    await tester.pump();
    int built() =>
        find.byType(MessageBubble, skipOffstage: false).evaluate().length;
    final first = built();
    await settle(tester);
    final arrived = built();

    expect(first, greaterThan(0));
    expect(arrived, greaterThan(first),
        reason: 'the rows beyond the screen come once the chat has arrived');
  });
}
