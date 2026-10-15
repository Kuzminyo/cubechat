import 'dart:io';

import 'package:cubechat/app.dart';
import 'package:cubechat/features/channels/data/channel_controller.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/accepted_terms.dart';
import 'support/hive_settle.dart';

/// A sent message makes room for itself the way Telegram's does: the
/// conversation rises with it, frame by frame.
///
/// Up to 1170 the new bubble faded in where it stood while everything above it
/// jumped up by its whole height on the first frame — "дерганая и не понятная"
/// (2026-10-15).
void main() {
  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_send_rise_');
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

  testWidgets('the conversation rises with a sent message, not before it',
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
    messages.append(
      '#room',
      Message(
        id: 'old',
        chatId: '#room',
        text: 'the one before',
        sentAt: DateTime.now().subtract(const Duration(hours: 1)),
        isMine: false,
        wireId: 'a' * 32,
      ),
    );
    await settle(tester, 10);
    await tester.tap(find.text('#room').first);
    await settle(tester);

    double before() => tester.getTopLeft(find.text('the one before')).dy;
    final rest = before();

    messages.append(
      '#room',
      Message(
        id: 'new',
        chatId: '#room',
        text: 'just sent',
        sentAt: DateTime.now(),
        isMine: true,
        wireId: 'b' * 32,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final early = rest - before();
    await settle(tester);
    final risen = rest - before();

    expect(risen, greaterThan(30), reason: 'the new message took its room');
    expect(early, lessThan(risen * 0.5),
        reason: 'the history jumped $early of $risen on the first frames');
  });
}
