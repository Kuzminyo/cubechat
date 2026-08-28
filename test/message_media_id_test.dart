import 'dart:io';

import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// Two fields that are useless unless they survive a restart.
///
/// [Message.mediaId] is what lets an administrator offer a photograph to
/// somebody who joined later without showing it to the whole room a second
/// time — the picture goes out under the id it first travelled with, and
/// insertion is idempotent on the hash of that id. A field that quietly fails
/// to persist would leave the replay minting fresh ids, which is the duplicate
/// it exists to avoid, and nothing about the code would look wrong.
///
/// [Message.forwardedFromId] is the same kind of thing for the line above a
/// forwarded message: without it the name is there and the tap goes nowhere.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final peerId = 'ab' * 32;
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_mediaid_');
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

  test('a photo keeps the id it travelled under across a restart', () async {
    var container = ProviderContainer();
    var messages = container.read(messagesControllerProvider.notifier);
    await messages.loaded;

    messages.append(
      peerId,
      Message(
        id: 'm1',
        chatId: peerId,
        text: 'image/jpeg',
        isMine: true,
        sentAt: DateTime.now(),
        status: MessageStatus.delivered,
        kind: MessageKind.image,
        wireId: 'cd' * 16,
        mediaId: '0f' * 16,
      ),
    );
    // The store debounces its writes and the container's dispose cancels the
    // pending timer, so a test that only settles loses the very thing it is
    // checking survives.
    await messages.flushPending();
    await settleBackgroundStorage();
    container.dispose();

    container = ProviderContainer();
    addTearDown(container.dispose);
    messages = container.read(messagesControllerProvider.notifier);
    await messages.loaded;

    final back = container.read(messagesControllerProvider)[peerId]!.single;
    expect(back.mediaId, '0f' * 16);
    expect(back.kind, MessageKind.image);
  });

  test('an attribution keeps the author it points at', () async {
    var container = ProviderContainer();
    var messages = container.read(messagesControllerProvider.notifier);
    await messages.loaded;

    messages.append(
      peerId,
      Message(
        id: 'm1',
        chatId: peerId,
        text: 'passed on',
        isMine: true,
        sentAt: DateTime.now(),
        status: MessageStatus.delivered,
        wireId: 'ef' * 16,
      ),
    );
    messages.applyForwardedFrom(
      peerId,
      'ef' * 16,
      'Anna',
      authorId: 'bc' * 32,
    );
    // The store debounces its writes and the container's dispose cancels the
    // pending timer, so a test that only settles loses the very thing it is
    // checking survives.
    await messages.flushPending();
    await settleBackgroundStorage();
    container.dispose();

    container = ProviderContainer();
    addTearDown(container.dispose);
    messages = container.read(messagesControllerProvider.notifier);
    await messages.loaded;

    final back = container.read(messagesControllerProvider)[peerId]!.single;
    expect(back.forwardedFrom, 'Anna');
    expect(
      back.forwardedFromId,
      'bc' * 32,
      reason: 'without it the header is a name that answers no tap',
    );
  });

  test('an attribution without a key stays a name', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final messages = container.read(messagesControllerProvider.notifier);
    await messages.loaded;

    messages.append(
      peerId,
      Message(
        id: 'm1',
        chatId: peerId,
        text: 'passed on',
        isMine: true,
        sentAt: DateTime.now(),
        status: MessageStatus.delivered,
        wireId: 'ef' * 16,
      ),
    );
    // What a v1 sender's attribution looks like, and what somebody who asked
    // not to be linked to gets.
    messages.applyForwardedFrom(peerId, 'ef' * 16, 'Anna');

    final back = container.read(messagesControllerProvider)[peerId]!.single;
    expect(back.forwardedFrom, 'Anna');
    expect(back.forwardedFromId, isNull);
  });
}
