import 'dart:io';

import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chats/data/saved_messages.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// History filed under a BLE address is history filed under a name that moves.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_strays_');
    Hive.init(tempDir.path);
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

  final pubkey = 'a' * 64;

  Message msg(String id) => Message(
        id: id,
        chatId: 'chat',
        text: id,
        sentAt: DateTime(2026),
        isMine: false,
      );

  test('a bucket keyed by a BLE address does not survive a load', () async {
    var container = ProviderContainer();
    var messages = container.read(messagesControllerProvider.notifier);
    await messages.loaded;

    // What older builds wrote: the same conversation under the pubkey and
    // under whatever address the phone was advertising at the time.
    messages.append(pubkey, msg('real'));
    messages.append('4D:43:5E:0E:9D:F7', msg('stray'));
    messages.append('#room', msg('channel'));
    messages.append(savedChatId, msg('note'));
    await messages.flushPending();
    await settleBackgroundStorage();
    container.dispose();

    container = ProviderContainer();
    addTearDown(container.dispose);
    messages = container.read(messagesControllerProvider.notifier);
    await messages.loaded;
    final state = container.read(messagesControllerProvider);

    expect(state[pubkey]?.single.id, 'real', reason: 'the real one stays');
    expect(state['#room']?.single.id, 'channel', reason: 'a room is durable');
    expect(state[savedChatId]?.single.id, 'note', reason: 'so is the notebook');
    expect(
      state.containsKey('4D:43:5E:0E:9D:F7'),
      isFalse,
      reason: 'an address is a name that moves; history cannot live under it',
    );
  });

  test('the drop is permanent, not just skipped in memory', () async {
    var container = ProviderContainer();
    var messages = container.read(messagesControllerProvider.notifier);
    await messages.loaded;
    messages.append('5E:60:41:2A:4B:1B', msg('stray'));
    await messages.flushPending();
    await settleBackgroundStorage();
    container.dispose();

    // First load removes it from disk...
    container = ProviderContainer();
    messages = container.read(messagesControllerProvider.notifier);
    await messages.loaded;
    await settleBackgroundStorage();
    container.dispose();

    // ...so a second one finds nothing to remove.
    container = ProviderContainer();
    addTearDown(container.dispose);
    messages = container.read(messagesControllerProvider.notifier);
    await messages.loaded;
    expect(
      container.read(messagesControllerProvider).containsKey('5E:60:41:2A:4B:1B'),
      isFalse,
    );
  });
}
