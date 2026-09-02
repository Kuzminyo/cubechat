import 'dart:io';

import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

const _chat =
    'e3f9fef4cdc7cd3955714c693cec935a778e58272954bf2706ab4417247f0b71';

Message _msg(String id, DateTime at) => Message(
      id: id,
      chatId: _chat,
      text: id,
      sentAt: at,
      isMine: false,
      wireId: id,
    );

void main() {
  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_clear_');
    Hive.init(tempDir.path);
    container = ProviderContainer();
  });

  tearDown(() async {
    container.dispose();
    await settleBackgroundStorage();
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  MessagesController messages() =>
      container.read(messagesControllerProvider.notifier);

  test('a clear takes the conversation as it stood when it was sent', () {
    final c = messages();
    final start = DateTime(2026, 9, 2, 17);
    c.append(_chat, _msg('one', start));
    c.append(_chat, _msg('two', start.add(const Duration(minutes: 1))));

    c.clearForChatUpTo(_chat, start.add(const Duration(minutes: 2)));

    expect(container.read(messagesControllerProvider)[_chat], isNull);
  });

  test('the same clear delivered again takes nothing more', () async {
    // The bug this exists for. A relay hands its backlog to whoever subscribes
    // next and our REQ deliberately overlaps the last ten minutes, so a clear
    // sent once arrives again on every launch. Unbounded, the second delivery
    // wiped the messages that had come in since — reported as a conversation
    // that was there and then was not.
    final c = messages();
    final start = DateTime(2026, 9, 2, 17);
    final clearedAt = start.add(const Duration(minutes: 2));
    c.append(_chat, _msg('one', start));
    await c.clearForChatUpTo(_chat, clearedAt);
    expect(container.read(messagesControllerProvider)[_chat], isNull);

    // Said after the clear, and nine minutes before the relay replays it.
    final since = _msg('later', clearedAt.add(const Duration(minutes: 5)));
    c.append(_chat, since);

    await c.clearForChatUpTo(_chat, clearedAt);

    expect(
      container.read(messagesControllerProvider)[_chat],
      [since],
      reason: 'a replayed clear must not take what arrived after it',
    );
  });

  test('a clear that waited keeps what the peer said afterwards', () async {
    // Not merely harmless — correct. Somebody who cleared while this phone was
    // off asked for the conversation up to that moment to go, and for what
    // they said next to stay.
    final c = messages();
    final start = DateTime(2026, 9, 2, 17);
    final clearedAt = start.add(const Duration(minutes: 1));
    final after = _msg('after', clearedAt.add(const Duration(minutes: 30)));
    c.append(_chat, _msg('before', start));
    c.append(_chat, after);

    await c.clearForChatUpTo(_chat, clearedAt);

    expect(container.read(messagesControllerProvider)[_chat], [after]);
  });

  test('a clear for a chat with nothing in it does nothing', () async {
    final c = messages();
    await c.clearForChatUpTo(_chat, DateTime(2026, 9, 2, 17));
    expect(container.read(messagesControllerProvider)[_chat], isNull);
  });
}
