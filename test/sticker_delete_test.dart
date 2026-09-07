// Two stickers, one deleted, one left.
//
// Reported after the shipped pack landed: sending two and deleting one took
// both away. What the two have in common is the file — a pack sticker is
// copied out of the bundle once and every send of it points at that same copy
// — so the question is whether anything keys a message by its picture rather
// than by itself.
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

  final chat = 'aa' * 32;
  const path = '/data/cubechat-stickers/builtin-cat-wave.webp';

  Message sticker(String id, String wireId) => Message(
        id: id,
        chatId: chat,
        text: Message.stickerMarkerFor('👋'),
        sentAt: DateTime(2026, 9, 7, 9, 31),
        isMine: true,
        kind: MessageKind.image,
        // The same file, which is the whole point: one copy per pack sticker.
        imagePath: path,
        imageMime: 'image/webp',
        wireId: wireId,
      );

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await hiveCipherProvider.wipe();
    tempDir = await Directory.systemTemp.createTemp('cubechat_stickdel_');
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

  MessagesController messages() =>
      container.read(messagesControllerProvider.notifier);

  test('deleting one of two identical stickers leaves the other', () async {
    final m = messages();
    await m.loaded;
    expect(m.append(chat, sticker('m1', 'w1')), isTrue);
    expect(m.append(chat, sticker('m2', 'w2')), isTrue);
    expect(m.forPeer(chat), hasLength(2));

    m.deleteLocal(chat, 'm1');

    expect(m.forPeer(chat).map((x) => x.id), ['m2']);
  });

  test('deleting for everyone takes one of them', () async {
    final m = messages();
    await m.loaded;
    m.append(chat, sticker('m1', 'w1'));
    m.append(chat, sticker('m2', 'w2'));

    expect(m.deleteMineByWireId(chat, 'w1'), isTrue);

    expect(m.forPeer(chat).map((x) => x.id), ['m2']);
  });

  test('the second send of the same sticker is not mistaken for the first',
      () async {
    // [append] refuses a message whose wireId is already there, which is what
    // makes a redelivered frame harmless. A pack sticker sent twice is two
    // messages and must not be caught by it — and it is not, because the wire
    // id comes from the media id, which is minted per send. Pinned because the
    // file is shared and looks like the obvious thing to key on.
    final m = messages();
    await m.loaded;
    expect(m.append(chat, sticker('m1', 'w1')), isTrue);
    expect(m.append(chat, sticker('m2', 'w2')), isTrue);
    expect(m.forPeer(chat), hasLength(2));
  });

  test('a redelivery of the same one is still refused', () async {
    final m = messages();
    await m.loaded;
    expect(m.append(chat, sticker('m1', 'w1')), isTrue);
    expect(m.append(chat, sticker('m2', 'w1')), isFalse);
    expect(m.forPeer(chat), hasLength(1));
  });
}
