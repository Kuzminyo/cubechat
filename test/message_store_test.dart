// History is a record per message now, not a list per conversation.
//
// The point of the change is the cost of a small edit: a reaction or a read
// receipt used to rewrite every message in the chat it landed in, so the price
// of the cheapest thing grew with the length of the conversation. These tests
// hold the three things that has to be true — the history that already exists
// survives the move, it comes back in the order it went in, and a one-message
// change writes one message.
import 'dart:io';

import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/core/storage/hive_init.dart';
import 'package:cubechat/features/chat/data/message_store.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  const chatId =
      'aa11bb22cc33dd44ee55ff6677889900aa11bb22cc33dd44ee55ff6677889900';
  const other =
      'bb22cc33dd44ee55ff6677889900aa11bb22cc33dd44ee55ff6677889900aa11';

  Message msg(String id, String text, {int minute = 0}) => Message(
        id: id,
        chatId: chatId,
        text: text,
        sentAt: DateTime(2026, 9, 6, 12, minute),
        isMine: false,
      );

  MessageStore newStore() => MessageStore(
        encode: MessagesController.encodeForTest,
        decode: MessagesController.decodeForTest,
      );

  /// Every key in the records box, so a test can count writes rather than
  /// describe them.
  Future<Box<Map<dynamic, dynamic>>> recordsBox() =>
      hiveCipherProvider.openEncryptedBox<Map<dynamic, dynamic>>(
        HiveBoxes.messageRecords,
      );

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await hiveCipherProvider.wipe();
    tempDir = await Directory.systemTemp.createTemp('cubechat_store_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    await hiveCipherProvider.wipe();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can briefly retain a Hive handle after close.
    }
  });

  test('a conversation survives a write and a reopen, in order', () async {
    final store = newStore();
    await store.load(isDurableChatId: (_) => true);
    final sent = [
      msg('m1', 'first', minute: 1),
      msg('m2', 'second', minute: 2),
      msg('m3', 'third', minute: 3),
    ];
    await store.write(chatId, sent);

    final reopened = newStore();
    final back = await reopened.load(isDurableChatId: (_) => true);
    expect(back[chatId]?.map((m) => m.text).toList(), [
      'first',
      'second',
      'third',
    ]);
  });

  test('order is the order it was appended in, not the order of the clock',
      () async {
    // A relay hands over a backlog whenever it reconnects, so a message
    // written earlier can be appended after one written later. The list reads
    // in arrival order today, and storage is not the place to change that.
    final store = newStore();
    await store.load(isDurableChatId: (_) => true);
    await store.write(chatId, [
      msg('m1', 'sent friday', minute: 50),
      msg('m2', 'sent tuesday, arrived now', minute: 1),
    ]);

    final back = await newStore().load(isDurableChatId: (_) => true);
    expect(back[chatId]?.map((m) => m.text).toList(), [
      'sent friday',
      'sent tuesday, arrived now',
    ]);
  });

  test('changing one message writes one record, not the conversation',
      () async {
    final store = newStore();
    await store.load(isDurableChatId: (_) => true);
    final history = [
      for (var i = 0; i < 50; i++) msg('m$i', 'message $i', minute: i),
    ];
    await store.write(chatId, history);

    // What a reaction does: rebuild the list with one element replaced. Every
    // other element is the same object, which is what makes the diff free.
    final edited = [...history]..[7] = history[7].copyWith(
        reactions: {
          'x': {'someone'},
        },
      );

    final box = await recordsBox();
    final before = {
      for (final key in box.keys) key: box.get(key).toString(),
    };
    await store.write(chatId, edited);
    final after = {
      for (final key in box.keys) key: box.get(key).toString(),
    };

    final changed = [
      for (final key in after.keys)
        if (before[key] != after[key]) key,
    ];
    expect(
      changed,
      hasLength(1),
      reason: 'a reaction on one message rewrote ${changed.length} records; '
          'the whole point of a record per message is that it rewrites one',
    );
    expect(changed.single, contains('m7'));
  });

  test('a message that is edited keeps its place', () async {
    final store = newStore();
    await store.load(isDurableChatId: (_) => true);
    final history = [
      msg('m1', 'first', minute: 1),
      msg('m2', 'second', minute: 2),
      msg('m3', 'third', minute: 3),
    ];
    await store.write(chatId, history);
    await store.write(chatId, [...history]..[0] = history[0].copyWith(
        text: 'first, corrected',
      ));

    final back = await newStore().load(isDurableChatId: (_) => true);
    expect(back[chatId]?.map((m) => m.text).toList(), [
      'first, corrected',
      'second',
      'third',
    ]);
  });

  test('a removed message is removed from disk', () async {
    final store = newStore();
    await store.load(isDurableChatId: (_) => true);
    final history = [
      msg('m1', 'first', minute: 1),
      msg('m2', 'second', minute: 2),
    ];
    await store.write(chatId, history);
    await store.write(chatId, [history[1]]);

    final back = await newStore().load(isDurableChatId: (_) => true);
    expect(back[chatId]?.map((m) => m.text).toList(), ['second']);
  });

  test('deleting a chat takes its records and leaves the others', () async {
    final store = newStore();
    await store.load(isDurableChatId: (_) => true);
    await store.write(chatId, [msg('m1', 'here', minute: 1)]);
    await store.write(other, [msg('m2', 'elsewhere', minute: 2)]);
    await store.deleteChat(chatId);

    final back = await newStore().load(isDurableChatId: (_) => true);
    expect(back.containsKey(chatId), isFalse);
    expect(back[other]?.single.text, 'elsewhere');
  });

  test('a bucket under a chat id that is not durable is dropped', () async {
    final store = newStore();
    await store.load(isDurableChatId: (_) => true);
    await store.write('AA:BB:CC:DD:EE:FF', [msg('m1', 'ble address', minute: 1)]);
    await store.write(chatId, [msg('m2', 'real', minute: 2)]);

    // The rule the previous format applied on the way in, applied here.
    final back = await newStore().load(
      isDurableChatId: (id) =>
          id.length == 64 && RegExp(r'^[0-9a-f]+$').hasMatch(id),
    );
    expect(back.keys, [chatId]);
  });

  group('summaries', () {
    test('a summary is written with the conversation and read back alone',
        () async {
      final store = newStore();
      await store.load(isDurableChatId: (_) => true);
      await store.loadSummaries();
      await store.write(chatId, [
        msg('m1', 'first', minute: 1),
        msg('m2', 'last thing said', minute: 2),
      ]);

      // A fresh launch that reads summaries and never touches history.
      final summaries = await newStore().loadSummaries();
      expect(summaries[chatId]?.last?.text, 'last thing said');
    });

    test('the unread count matches what full history would say', () async {
      final store = newStore();
      await store.load(isDurableChatId: (_) => true);
      await store.loadSummaries();
      final history = [
        msg('m1', 'theirs', minute: 1),
        msg('m2', 'theirs', minute: 2),
        msg('m3', 'theirs', minute: 3),
      ];
      await store.write(chatId, history);

      final summary = (await newStore().loadSummaries())[chatId]!;
      expect(summary.unreadAfter(null), 3, reason: 'never opened');
      expect(summary.unreadAfter(DateTime(2026, 9, 6, 12, 2)), 1);
      expect(summary.unreadAfter(DateTime(2026, 9, 6, 12, 3)), 0);
    });

    test('our own messages are not unread', () async {
      final store = newStore();
      await store.load(isDurableChatId: (_) => true);
      await store.loadSummaries();
      await store.write(chatId, [
        msg('m1', 'theirs', minute: 1),
        Message(
          id: 'm2',
          chatId: chatId,
          text: 'mine',
          sentAt: DateTime(2026, 9, 6, 12, 2),
          isMine: true,
        ),
      ]);

      final summary = (await newStore().loadSummaries())[chatId]!;
      expect(summary.unreadAfter(null), 1);
    });

    test('the unread times are sorted, so a backlog counts correctly',
        () async {
      // A relay replays what it held, so a message written earlier arrives
      // after one written later. Counting "newer than the marker" over an
      // unsorted list would stop at the first old one.
      final store = newStore();
      await store.load(isDurableChatId: (_) => true);
      await store.loadSummaries();
      await store.write(chatId, [
        msg('m1', 'arrived first, written last', minute: 50),
        msg('m2', 'arrived second, written first', minute: 1),
        msg('m3', 'arrived third, written in between', minute: 20),
      ]);

      final summary = (await newStore().loadSummaries())[chatId]!;
      expect(summary.unreadAfter(DateTime(2026, 9, 6, 12, 10)), 2);
    });

    test('deleting a conversation takes its summary with it', () async {
      final store = newStore();
      await store.load(isDurableChatId: (_) => true);
      await store.loadSummaries();
      await store.write(chatId, [msg('m1', 'here', minute: 1)]);
      await store.deleteChat(chatId);

      expect((await newStore().loadSummaries()).containsKey(chatId), isFalse);
    });
  });

  group('importing the previous format', () {
    /// Write history the old way: one entry per chat, holding the whole list.
    Future<void> seedV1(Map<String, List<Message>> chats) async {
      final old = await hiveCipherProvider
          .openEncryptedBox<List<dynamic>>(HiveBoxes.messages);
      for (final entry in chats.entries) {
        await old.put(
          entry.key,
          entry.value.map(MessagesController.encodeForTest).toList(),
        );
      }
    }

    test('history written by the old build comes back intact', () async {
      await seedV1({
        chatId: [
          msg('m1', 'first', minute: 1),
          msg('m2', 'second', minute: 2),
        ],
        other: [msg('m3', 'elsewhere', minute: 3)],
      });

      final back = await newStore().load(isDurableChatId: (_) => true);
      expect(back[chatId]?.map((m) => m.text).toList(), ['first', 'second']);
      expect(back[other]?.single.text, 'elsewhere');
    });

    test('the old entries are left where they are', () async {
      // Deliberately not deleted: this is everybody's whole history and the
      // new shape has not run on a real phone before. A copy left behind costs
      // disk and nothing else.
      await seedV1({
        chatId: [msg('m1', 'first', minute: 1)],
      });
      await newStore().load(isDurableChatId: (_) => true);

      final old = await hiveCipherProvider
          .openEncryptedBox<List<dynamic>>(HiveBoxes.messages);
      expect(old.get(chatId), isNotNull);
    });

    test('it does not import twice, and does not undo a later delete',
        () async {
      await seedV1({
        chatId: [msg('m1', 'first', minute: 1)],
      });

      final first = newStore();
      await first.load(isDurableChatId: (_) => true);
      await first.deleteChat(chatId);

      // A second launch. The old bucket is still on disk; the import must not
      // read it again and resurrect a conversation the user deleted.
      final second = await newStore().load(isDurableChatId: (_) => true);
      expect(second.containsKey(chatId), isFalse);
    });
  });
}
