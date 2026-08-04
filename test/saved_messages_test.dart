import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/features/chat/data/messages_controller.dart';
import 'package:cubechat/features/chat/models/message.dart';
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
    container = ProviderContainer(
      overrides: [
        // path_provider needs a platform to answer; the notes only need a
        // folder that exists.
        savedNotesDirectoryProvider.overrideWith(
          (ref) async => Directory(
            '${tempDir.path}${Platform.pathSeparator}notes',
          ),
        ),
      ],
    );
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

  test('a photo, a file and a voice note are notes too', () async {
    // Every media path used to reach for a recipient pubkey and throw
    // "no recipient pubkey for @saved" — at the one conversation that cannot
    // have one. Nothing here goes on a wire; it goes on the disk.
    final notes = container.read(savedMessagesControllerProvider);
    final source = File('${tempDir.path}${Platform.pathSeparator}конспект.pdf');
    await source.writeAsBytes(List<int>.filled(64, 7));

    await notes.saveImage(Uint8List.fromList([1, 2, 3]), caption: 'дах');
    await notes.saveFile(source, fileName: 'конспект.pdf',
        mime: 'application/pdf');
    await notes.saveVoice(source, durationMs: 8000);

    final saved = container.read(messagesControllerProvider)[savedChatId]!;
    expect(saved, hasLength(3));
    expect(saved.every((m) => m.isMine), isTrue);

    final image = saved[0];
    expect(image.kind, MessageKind.image);
    expect(image.text, 'дах', reason: 'the caption rides where it always does');
    expect(File(image.imagePath!).existsSync(), isTrue);

    final file = saved[1];
    expect(file.kind, MessageKind.file);
    expect(file.fileName, 'конспект.pdf');
    expect(file.fileBytes, 64);
    // Copied, not referenced: clearing the source must not empty the note.
    expect(file.filePath, isNot(source.path));
    expect(File(file.filePath!).existsSync(), isTrue);

    final voice = saved[2];
    expect(voice.kind, MessageKind.audio);
    expect(voice.audioDurationMs, 8000);
    expect(File(voice.audioPath!).existsSync(), isTrue);
  });

  test('an empty note is not worth a bubble', () async {
    final notes = container.read(savedMessagesControllerProvider);
    await notes.saveText('');
    await notes.saveText('   \n  ');
    expect(container.read(messagesControllerProvider)[savedChatId], isNull);
  });
}
