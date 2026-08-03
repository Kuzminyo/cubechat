import 'dart:io';

import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'support/hive_settle.dart';

/// Read receipts in a channel are not the 1:1 feature with a wider net.
///
/// A 1:1 chat flips one status because there is exactly one person it could
/// have come from. A channel has no member roster at all — holding the key is
/// membership, joining tells nobody, and a message goes out as a blind
/// broadcast — so the only honest answer to "who has read this" is the list of
/// people who said so. That makes the state additive and per-reader, and these
/// tests pin the properties that follow from it.
void main() {
  // The Hive cipher reads its key through a platform channel; without a binding
  // it falls back to a session-only key and logs about it.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_chanread_test_');
    Hive.init(tempDir.path);
    container = ProviderContainer();
  });

  tearDown(() async {
    await settleBackgroundStorage();
    container.dispose();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the Hive files briefly after close.
    }
  });

  MessagesController notifier() =>
      container.read(messagesControllerProvider.notifier);

  const channel = '#general';

  Message inbound(String wireId) => Message(
        id: 'local-$wireId',
        chatId: channel,
        text: 'hello',
        sentAt: DateTime(2026, 8, 3, 12),
        isMine: false,
        wireId: wireId,
      );

  Message mine(String wireId) => Message(
        id: 'local-$wireId',
        chatId: channel,
        text: 'mine',
        sentAt: DateTime(2026, 8, 3, 12),
        isMine: true,
        wireId: wireId,
      );

  Message only(String chatId) =>
      container.read(messagesControllerProvider)[chatId]!.single;

  test('a receipt records the reader against the right message', () {
    notifier().append(channel, mine('aa'));
    notifier().append(channel, inbound('bb'));

    notifier().applyChannelRead(
      channel,
      readerId: 'reader-1',
      readerName: 'Alice',
      wireIds: {'aa'},
      at: DateTime(2026, 8, 3, 12, 5),
    );

    final msgs = container.read(messagesControllerProvider)[channel]!;
    expect(msgs.first.readBy.keys, ['reader-1']);
    expect(msgs.first.readBy['reader-1']!.name, 'Alice');
    expect(msgs.first.readBy['reader-1']!.at, DateTime(2026, 8, 3, 12, 5));
    expect(msgs[1].readBy, isEmpty,
        reason: 'only the acknowledged wireId is touched');
  });

  test('readers accumulate rather than replace each other', () {
    notifier().append(channel, mine('aa'));
    for (final name in ['Alice', 'Bohdan', 'Chris']) {
      notifier().applyChannelRead(
        channel,
        readerId: 'id-$name',
        readerName: name,
        wireIds: {'aa'},
        at: DateTime(2026, 8, 3, 12, 5),
      );
    }
    expect(only(channel).readBy.length, 3);
    expect(
      only(channel).readBy.values.map((r) => r.name),
      containsAll(['Alice', 'Bohdan', 'Chris']),
    );
  });

  test('a resent receipt keeps the first timestamp', () {
    // Mesh and relay both redeliver, and a duplicate means the frame was sent
    // again — not that they read it again. Letting the later copy win would
    // walk every reader's time forward on every resend.
    notifier().append(channel, mine('aa'));
    notifier().applyChannelRead(
      channel,
      readerId: 'reader-1',
      readerName: 'Alice',
      wireIds: {'aa'},
      at: DateTime(2026, 8, 3, 12, 5),
    );
    notifier().applyChannelRead(
      channel,
      readerId: 'reader-1',
      readerName: 'Alice',
      wireIds: {'aa'},
      at: DateTime(2026, 8, 3, 12, 30),
    );
    expect(only(channel).readBy.length, 1);
    expect(only(channel).readBy['reader-1']!.at, DateTime(2026, 8, 3, 12, 5));
  });

  test('a reader is capped so one message cannot grow without limit', () {
    // Nothing stops a peer minting fresh signing keys, and every receipt is
    // storage on our device.
    notifier().append(channel, mine('aa'));
    for (var i = 0; i < MessagesController.maxReadersPerMessage + 20; i++) {
      notifier().applyChannelRead(
        channel,
        readerId: 'reader-$i',
        readerName: 'R$i',
        wireIds: {'aa'},
        at: DateTime(2026, 8, 3, 12, 5),
      );
    }
    expect(
      only(channel).readBy.length,
      MessagesController.maxReadersPerMessage,
    );
  });

  test('an unknown wireId and an unknown chat are both no-ops', () {
    notifier().append(channel, mine('aa'));
    notifier().applyChannelRead(
      channel,
      readerId: 'reader-1',
      readerName: 'Alice',
      wireIds: {'does-not-exist'},
      at: DateTime(2026, 8, 3, 12, 5),
    );
    expect(only(channel).readBy, isEmpty);

    // Must not throw for a channel we have no history for.
    notifier().applyChannelRead(
      '#never-joined',
      readerId: 'reader-1',
      readerName: 'Alice',
      wireIds: {'aa'},
      at: DateTime(2026, 8, 3, 12, 5),
    );
  });

  test('readBy survives an encode/decode round trip', () {
    // The reader list is only useful if it is still there after a restart.
    final original = mine('aa').copyWith(
      readBy: {
        'reader-1': ChannelRead(name: 'Alice', at: DateTime(2026, 8, 3, 12, 5)),
        'reader-2': ChannelRead(name: 'Bohdan', at: DateTime(2026, 8, 3, 12, 9)),
      },
    );
    final restored = MessagesController.decodeForTest(
      MessagesController.encodeForTest(original),
    );
    expect(restored.readBy.length, 2);
    expect(restored.readBy['reader-1']!.name, 'Alice');
    expect(restored.readBy['reader-1']!.at, DateTime(2026, 8, 3, 12, 5));
    expect(restored.readBy['reader-2']!.at, DateTime(2026, 8, 3, 12, 9));
  });
}
