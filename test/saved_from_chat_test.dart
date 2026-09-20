import 'dart:io';

import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chats/data/saved_messages.dart';
import 'package:cubechat/features/chats/data/saved_tags_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

void main() {
  // Tags live in the encrypted settings box, and its key comes from the
  // secure store.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('cubechat_saved_from_');
    Hive.init(tempDir.path);
    container = ProviderContainer(
      overrides: [
        savedNotesDirectoryProvider.overrideWith(
          (ref) async => Directory(
            '${tempDir.path}${Platform.pathSeparator}notes',
          ),
        ),
      ],
    );
  });

  tearDown(() async {
    // Settle first, dispose second. SavedTagsController.build kicks off an
    // async _start that reads a provider when the box opens; disposing the
    // container while that is still in flight throws "read from a
    // ProviderContainer that was already disposed" out of a zone the test
    // cannot catch.
    await settleBackgroundStorage();
    container.dispose();
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('saving a note hands back its id, so a tag has something to land on',
      () async {
    // Without the id the caller cannot tag what it just saved, and tagging at
    // the moment of saving is the whole of the Pro half of this feature.
    final saved = container.read(savedMessagesControllerProvider);
    final id = await saved.saveText('a note');

    expect(id, isNotNull);
    final notes = container.read(messagesControllerProvider)[savedChatId];
    expect(notes, isNotNull);
    expect(notes!.single.id, id);
    expect(notes.single.text, 'a note');
  });

  test('an empty note is not saved and has no id', () async {
    final saved = container.read(savedMessagesControllerProvider);
    expect(await saved.saveText('   '), isNull);
    expect(container.read(messagesControllerProvider)[savedChatId], isNull);
  });

  test('a picture is copied in, so deleting the original keeps the note',
      () async {
    // A note that points at the conversation's file is not a kept copy: the
    // chat's media gets cleared, and the note turns into a broken box.
    final source = File('${tempDir.path}${Platform.pathSeparator}shot.jpg');
    await source.writeAsBytes(<int>[1, 2, 3, 4]);
    final saved = container.read(savedMessagesControllerProvider);

    final id = await saved.saveCopyOf(
      Message(
        id: 'm1',
        chatId: 'a' * 64,
        text: 'look',
        sentAt: DateTime(2026),
        isMine: false,
        kind: MessageKind.image,
        imagePath: source.path,
        imageMime: 'image/jpeg',
      ),
    );
    await source.delete();

    final note = container.read(messagesControllerProvider)[savedChatId]!.single;
    expect(note.id, id);
    expect(note.kind, MessageKind.image);
    expect(note.imagePath, isNot(source.path));
    expect(File(note.imagePath!).existsSync(), isTrue);
    expect(File(note.imagePath!).readAsBytesSync(), <int>[1, 2, 3, 4]);
  });

  test('a message whose file is gone still keeps its words', () async {
    // Media cleared out of the chat is the common case, and losing the text
    // with it would be a worse answer than keeping the sentence.
    final saved = container.read(savedMessagesControllerProvider);
    final id = await saved.saveCopyOf(
      Message(
        id: 'm2',
        chatId: 'a' * 64,
        text: 'the caption survived',
        sentAt: DateTime(2026),
        isMine: false,
        kind: MessageKind.image,
        imagePath: '${tempDir.path}${Platform.pathSeparator}missing.jpg',
      ),
    );

    final note = container.read(messagesControllerProvider)[savedChatId]!.single;
    expect(note.id, id);
    expect(note.text, 'the caption survived');
  });

  test('the id it returns is the one a tag attaches to', () async {
    final saved = container.read(savedMessagesControllerProvider);
    final id = await saved.saveText('tag me');
    await container.read(savedTagsProvider.notifier).setTag(id!, '🔖');

    expect(container.read(savedTagsProvider)[id], '🔖');
  });
}
