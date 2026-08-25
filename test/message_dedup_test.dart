import 'dart:io';

import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/core/storage/hive_init.dart';
import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'support/hive_settle.dart';

/// A relay replays its stored backlog to every fresh subscription, so the same
/// message reaches us again on each launch. These tests pin the layer that has
/// to make that harmless: the message store itself.
void main() {
  // A real chat id, because its shape now matters: history is only kept under
  // a pubkey, a channel name or the notebook — see MessagesController, which
  // drops anything filed under a BLE address, since that name moves.
  final peerId = 'ab' * 32;

  // The Hive cipher reads its key through a platform channel; without a binding
  // it falls back to a session-only key and logs about it.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_dedup_test_');
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

  Message inbound(String text, {String? wireId}) => Message(
        id: 'm${DateTime.now().microsecondsSinceEpoch}$text',
        chatId: peerId,
        text: text,
        sentAt: DateTime(2026, 7, 26, 16, 8),
        isMine: false,
        wireId: wireId,
      );

  test('a second copy of the same wireId is not appended', () {
    final n = notifier();
    expect(n.append(peerId, inbound('Оно', wireId: 'aa' * 16)), isTrue);
    // Same message re-delivered — over a relay backlog replay, or by a second
    // path — after the in-memory dedup cache expired or a restart emptied it.
    expect(n.append(peerId, inbound('Оно', wireId: 'aa' * 16)), isFalse);

    expect(n.forPeer(peerId), hasLength(1));
  });

  test('distinct wireIds both land, even with identical text', () {
    final n = notifier();
    n.append(peerId, inbound('Оно', wireId: 'aa' * 16));
    n.append(peerId, inbound('Оно', wireId: 'bb' * 16));
    expect(n.forPeer(peerId), hasLength(2));
  });

  test('messages without a wireId are never deduped', () {
    final n = notifier();
    // Two photos in a row are genuinely two messages, and legacy history has no
    // wireId to compare on.
    expect(n.append(peerId, inbound('image/jpeg')), isTrue);
    expect(n.append(peerId, inbound('image/jpeg')), isTrue);
    expect(n.forPeer(peerId), hasLength(2));
  });

  test('dedup is per chat, not global', () {
    final n = notifier();
    n.append('peer-a', inbound('hi', wireId: 'aa' * 16));
    // The same message fanned out to a second bucket for an open ChatScreen.
    expect(n.append('peer-b', inbound('hi', wireId: 'aa' * 16)), isTrue);
    expect(n.forPeer('peer-b'), hasLength(1));
  });

  group('read receipts', () {
    Message mine(String text, {required String wireId}) => Message(
          id: 'm-$wireId',
          chatId: peerId,
          text: text,
          sentAt: DateTime(2026, 7, 26, 16, 8),
          isMine: true,
          status: MessageStatus.delivered,
          wireId: wireId,
        );

    test('markRead stamps the time the receipt landed', () async {
      final n = notifier();
      await n.loaded;
      n.append(peerId, mine('привет', wireId: 'aa' * 16));
      final before = DateTime.now();
      n.markRead(peerId, {'aa' * 16});

      final m = n.forPeer(peerId).single;
      expect(m.status, MessageStatus.read);
      // Our clock, not the peer's: it has to be comparable with sentAt and the
      // rest of the timeline.
      expect(m.readAt, isNotNull);
      expect(m.readAt!.isBefore(before.subtract(const Duration(seconds: 1))),
          isFalse);
    });

    test('a repeated receipt keeps the first read time', () async {
      final n = notifier();
      await n.loaded;
      n.append(peerId, mine('привет', wireId: 'aa' * 16));
      n.markRead(peerId, {'aa' * 16});
      final first = n.forPeer(peerId).single.readAt;

      await Future<void>.delayed(const Duration(milliseconds: 5));
      n.markRead(peerId, {'aa' * 16});
      expect(n.forPeer(peerId).single.readAt, first);
    });

    test('a receipt never touches the peer\'s own messages', () async {
      final n = notifier();
      await n.loaded;
      n.append(peerId, inbound('їх', wireId: 'bb' * 16));
      n.markRead(peerId, {'bb' * 16});
      final m = n.forPeer(peerId).single;
      expect(m.status, isNot(MessageStatus.read));
      expect(m.readAt, isNull);
    });

    test('the read time survives a restart', () async {
      final n = notifier();
      await n.loaded; // box open, so the writes below actually persist
      n.append(peerId, mine('привет', wireId: 'aa' * 16));
      n.markRead(peerId, {'aa' * 16});
      final stamped = n.forPeer(peerId).single.readAt;
      // Writes are coalesced behind a short debounce, so ask for them rather
      // than sleeping past it — the claim is that the value reaches disk, not
      // that it does so within some number of milliseconds.
      await n.flushPending();

      final fresh = ProviderContainer();
      addTearDown(fresh.dispose);
      final restored = fresh.read(messagesControllerProvider.notifier);
      await restored.loaded;
      expect(restored.forPeer(peerId).single.readAt, stamped);
    });
  });

  // Regression: testers accumulated one extra copy of their whole off-mesh
  // history per launch. Fixing append() stops it growing, but the copies already
  // on disk have to be collapsed on load or the chat stays visibly duplicated.
  test('duplicates already on disk are healed when history loads', () async {
    Map<String, dynamic> stored(String text, String wireId) => {
          'id': 'm$wireId$text',
          'chatId': peerId,
          'text': text,
          'sentAtIso': DateTime(2026, 7, 26, 16, 8).toIso8601String(),
          'isMine': false,
          'status': 'delivered',
          'kind': 'text',
          'wireId': wireId,
        };

    final box = await hiveCipherProvider
        .openEncryptedBox<List<dynamic>>(HiveBoxes.messages);
    await box.put(peerId, [
      stored('Оно', 'aa' * 16),
      stored('Дублируется', 'bb' * 16),
      stored('Оно', 'aa' * 16), // second launch re-downloaded the backlog
      stored('Дублируется', 'bb' * 16),
      stored('Оно', 'aa' * 16), // third launch
      stored('Дублируется', 'bb' * 16),
    ]);

    final fresh = ProviderContainer();
    addTearDown(fresh.dispose);
    final n = fresh.read(messagesControllerProvider.notifier);
    await n.loaded;

    expect(
      n.forPeer(peerId).map((m) => m.text),
      ['Оно', 'Дублируется'],
    );
    // …and the repair is written back, so it doesn't have to run again.
    await n.flushPending();
    expect(box.get(peerId), hasLength(2));
  });
}
