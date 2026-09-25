// A4: "Hide" takes someone else's message off this phone at once, and the
// undo toast puts it back where it was — not at the bottom as if it had just
// arrived, and not twice if it arrived again in the meantime.
import 'dart:io';

import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  final chat = 'bb' * 32;

  Message incoming(String id, int minute) => Message(
        id: id,
        chatId: chat,
        text: 'message $id',
        sentAt: DateTime(2026, 9, 25, 10, minute),
        isMine: false,
        wireId: 'w$id',
      );

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await hiveCipherProvider.wipe();
    tempDir = await Directory.systemTemp.createTemp('cubechat_hide_');
    Hive.init(tempDir.path);
    container = ProviderContainer();
  });

  tearDown(() async {
    container.dispose();
    await settleBackgroundStorage();
    await Hive.close();
    await hiveCipherProvider.wipe();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the Hive files briefly after close.
    }
  });

  test('hide then undo restores the message at its own place', () async {
    final m = container.read(messagesControllerProvider.notifier);
    await m.loaded;
    m
      ..append(chat, incoming('a', 1))
      ..append(chat, incoming('b', 2))
      ..append(chat, incoming('c', 3));

    final hidden = m.forPeer(chat)[1];
    m.deleteLocal(chat, hidden.id);
    expect(m.forPeer(chat).map((x) => x.id), ['a', 'c']);

    m.restoreLocal(chat, hidden, 1);
    expect(m.forPeer(chat).map((x) => x.id), ['a', 'b', 'c']);
  });

  test('undo does not duplicate a message that came back meanwhile', () async {
    final m = container.read(messagesControllerProvider.notifier);
    await m.loaded;
    m
      ..append(chat, incoming('a', 1))
      ..append(chat, incoming('b', 2));

    final hidden = m.forPeer(chat)[1];
    m.deleteLocal(chat, hidden.id);
    m.append(
      chat,
      Message(
        id: 'b2',
        chatId: chat,
        text: hidden.text,
        sentAt: hidden.sentAt,
        isMine: false,
        wireId: hidden.wireId,
      ),
    );

    m.restoreLocal(chat, hidden, 1);
    expect(m.forPeer(chat), hasLength(2));
  });
}
