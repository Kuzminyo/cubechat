import 'dart:io';

import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chats/data/saved_messages.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

void main() {
  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_saved_');
    Hive.init(tempDir.path);
    container = ProviderContainer();
  });

  tearDown(() async {
    container.dispose();
    await settleBackgroundStorage();
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('the reserved id cannot collide with a peer or a channel', () {
    // A peer chat is keyed by 64 hex characters and a channel starts with '#'.
    // If this ever overlapped, saved notes would land in someone's
    // conversation — or worse, be sent there.
    expect(isSavedChat(savedChatId), isTrue);
    expect(savedChatId.startsWith('#'), isFalse);
    expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(savedChatId), isFalse);
    expect(isSavedChat('a' * 64), isFalse);
    expect(isSavedChat('#general'), isFalse);
  });

  test('a note lands in its own conversation, as ours', () async {
    await container.read(savedMessagesControllerProvider).saveText('  buy milk ');
    final saved =
        container.read(messagesControllerProvider)[savedChatId] ?? const [];

    expect(saved, hasLength(1));
    expect(saved.single.text, 'buy milk', reason: 'trimmed');
    expect(saved.single.chatId, savedChatId);
    // Every note here was written by the person reading it; rendering one as
    // though someone else spoke is a lie the bubble colour tells at a glance.
    expect(saved.single.isMine, isTrue);
  });

  test('an empty note is not worth a bubble', () async {
    final notes = container.read(savedMessagesControllerProvider);
    await notes.saveText('');
    await notes.saveText('   \n  ');
    expect(container.read(messagesControllerProvider)[savedChatId], isNull);
  });
}
