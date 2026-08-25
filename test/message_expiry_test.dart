import 'dart:io';

import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// A deadline on one message, where auto-delete is a rule for a whole
/// conversation: the sentence you would rather not leave lying around, in a
/// chat you otherwise want whole.
///
/// Local, like auto-delete itself — their copy is theirs, and a demand is what
/// this could never honestly be.
void main() {
  // A real chat id: history is only kept under a pubkey, a channel name or
  // the notebook, since a BLE address is a name that moves.
  final alice = 'ac' * 32;

  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_expiry_');
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

  Message note(String id, {DateTime? expires}) => Message(
        id: id,
        chatId: alice,
        text: id,
        sentAt: DateTime(2026),
        isMine: true,
        expiresAt: expires,
      );

  test('a message without a deadline is never swept', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final messages = container.read(messagesControllerProvider.notifier);
    await messages.loaded;

    messages.append(alice, note('keep'));
    messages.pruneExpiredMessages();
    expect(messages.forPeer(alice), hasLength(1));
  });

  test('a deadline in the past takes that message and nothing else', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final messages = container.read(messagesControllerProvider.notifier);
    await messages.loaded;

    messages.append(alice, note('keep'));
    messages.append(
      alice,
      note('gone', expires: DateTime.now().subtract(const Duration(minutes: 1))),
    );
    messages.append(
      alice,
      note('later', expires: DateTime.now().add(const Duration(hours: 1))),
    );

    messages.pruneExpiredMessages();
    final left = messages.forPeer(alice).map((m) => m.id).toList();
    expect(left, ['keep', 'later']);
  });

  test('a deadline can be taken back off', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final messages = container.read(messagesControllerProvider.notifier);
    await messages.loaded;

    messages.append(alice, note('m1'));
    messages.setExpiry(
      alice,
      'm1',
      DateTime.now().subtract(const Duration(seconds: 1)),
    );
    expect(messages.forPeer(alice).single.expiresAt, isNotNull);

    messages.setExpiry(alice, 'm1', null);
    expect(messages.forPeer(alice).single.expiresAt, isNull);
    messages.pruneExpiredMessages();
    expect(messages.forPeer(alice), hasLength(1),
        reason: 'clearing the timer has to actually clear it');
  });

  test('the deadline survives a round trip through storage', () async {
    // It is stored as milliseconds beside the message, so a phone restarted
    // between setting the timer and its expiry still honours it.
    final at = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().add(const Duration(hours: 2)).millisecondsSinceEpoch,
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final messages = container.read(messagesControllerProvider.notifier);
    await messages.loaded;
    messages.append(alice, note('m1', expires: at));

    // Flush the debounced write rather than race it: the persist timer is
    // 400 ms and the settle delay is shorter, so without this the second
    // container reads a box the first one had not written yet.
    await messages.flushPending();
    await settleBackgroundStorage();
    final second = ProviderContainer();
    addTearDown(second.dispose);
    final reopened = second.read(messagesControllerProvider.notifier);
    await reopened.loaded;

    expect(reopened.forPeer(alice).single.expiresAt, at);
  });
}
