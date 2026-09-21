import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../chat/data/messages_controller.dart';
import '../../chat/models/message.dart';

/// The reserved chat id for notes to yourself.
///
/// `@` cannot collide with either of the other two kinds: a peer chat is keyed
/// by 64 hex characters, a channel starts with `#`. Reserved rather than
/// derived from your own pubkey so the notes survive an identity change —
/// losing everything you saved because a key rotated would be a surprising way
/// to lose it.
const String savedChatId = '@saved';

bool isSavedChat(String chatId) => chatId == savedChatId;

/// Notes to yourself, kept on this device.
///
/// Nothing is sent: there is no peer, no session, no relay. A saved message is
/// written straight into the same store every other conversation uses, which is
/// what makes it searchable, pinnable and forwardable like anything else — and
/// what makes it obey the same Emergency Wipe.
///
/// It also means a saved note never leaves the phone, and there is deliberately
/// no sync: this app has no server to sync through, and inventing one for a
/// scratchpad would be the largest possible answer to the smallest question.
class SavedMessagesController {
  SavedMessagesController(this._ref);

  final Ref _ref;
  static const _uuid = Uuid();

  /// Where a saved attachment lives: the app's own storage, under a name it
  /// cannot collide on. The bytes have to outlive the picker's temporary copy
  /// and the cache directory both — a note you wrote a month ago should still
  /// have its photo.
  Future<File> _store(String suffix) async {
    final notes = await _ref.read(savedNotesDirectoryProvider.future);
    if (!await notes.exists()) await notes.create(recursive: true);
    return File('${notes.path}${Platform.pathSeparator}'
        '${_uuid.v4()}$suffix');
  }

  /// A photo kept as a note. Nothing is sent, so nothing is downscaled either:
  /// the encoder exists to fit a picture through Bluetooth, and there is no
  /// Bluetooth on this path.
  Future<String?> saveImage(
    Uint8List bytes, {
    String mime = 'image/jpeg',
    String? caption,
  }) async {
    if (bytes.isEmpty) return null;
    final file = await _store('.jpg');
    await file.writeAsBytes(bytes, flush: true);
    return _append(
      kind: MessageKind.image,
      text: caption ?? mime,
      imagePath: file.path,
      imageMime: mime,
    );
  }

  /// A file kept as a note, copied in so clearing the source changes nothing.
  Future<String?> saveFile(
    File source, {
    required String fileName,
    required String mime,
  }) async {
    final safe = fileName.trim().isEmpty ? 'file' : fileName.trim();
    final dot = safe.lastIndexOf('.');
    final copy = await _store(dot < 0 ? '' : safe.substring(dot));
    await source.copy(copy.path);
    return _append(
      kind: MessageKind.file,
      text: mime,
      filePath: copy.path,
      fileName: safe,
      fileBytes: await copy.length(),
    );
  }

  /// A voice note to yourself.
  Future<String?> saveVoice(
    File source, {
    required int durationMs,
    String mime = 'audio/aac',
  }) async {
    // Opus notes are Ogg; the extension says so to anything that opens one.
    final copy = await _store(
      mime.toLowerCase().startsWith('audio/ogg') ? '.opus' : '.m4a',
    );
    await source.copy(copy.path);
    return _append(
      kind: MessageKind.audio,
      text: mime,
      audioPath: copy.path,
      audioMime: mime,
      audioDurationMs: durationMs,
    );
  }

  /// Returns the id of the note it wrote, so a caller can tag what it just
  /// saved. Tagging at the moment of saving needs the id, and there is no way
  /// back to it from here once the append has happened.
  Future<String> _append({
    required MessageKind kind,
    required String text,
    String? imagePath,
    String? imageMime,
    String? audioPath,
    String? audioMime,
    int? audioDurationMs,
    String? filePath,
    String? fileName,
    int? fileBytes,
  }) async {
    final id = _uuid.v4();
    await _ref.read(messagesControllerProvider.notifier).append(
          savedChatId,
          Message(
            id: id,
            chatId: savedChatId,
            text: text,
            sentAt: DateTime.now(),
            isMine: true,
            status: MessageStatus.read,
            kind: kind,
            imagePath: imagePath,
            imageMime: imageMime,
            audioPath: audioPath,
            audioMime: audioMime,
            audioDurationMs: audioDurationMs,
            filePath: filePath,
            fileName: fileName,
            fileBytes: fileBytes,
          ),
        );
    return id;
  }

  /// Keep a copy of a message from a conversation.
  ///
  /// A copy, not a reference: the bytes of a picture, a file or a voice note
  /// are written into the notes folder, so deleting the conversation — or the
  /// message, or the chat's media — leaves the note intact. That is the whole
  /// point of keeping it.
  ///
  /// Null when there was nothing to keep. Falls back to the text for any kind
  /// whose file is missing, which is what a message whose media was cleared
  /// still has.
  Future<String?> saveCopyOf(Message message) async {
    final image = message.imagePath;
    if (image != null && await File(image).exists()) {
      return saveImage(
        await File(image).readAsBytes(),
        mime: message.imageMime ?? 'image/jpeg',
        caption: message.text.trim().isEmpty ? null : message.text,
      );
    }
    final audio = message.audioPath;
    if (audio != null && await File(audio).exists()) {
      return saveVoice(
        File(audio),
        durationMs: message.audioDurationMs ?? 0,
        mime: message.audioMime ?? 'audio/aac',
      );
    }
    final file = message.filePath;
    if (file != null && await File(file).exists()) {
      return saveFile(
        File(file),
        fileName: message.fileName ?? 'file',
        mime: message.text,
      );
    }
    return saveText(message.text);
  }

  /// Null when there was nothing to save — an empty note is not a note.
  Future<String?> saveText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final id = _uuid.v4();
    await _ref.read(messagesControllerProvider.notifier).append(
          savedChatId,
          Message(
            id: id,
            chatId: savedChatId,
            text: trimmed,
            sentAt: DateTime.now(),
            // Yours, always: every note here was written by you, and rendering
            // some of them as though someone else spoke would be a lie the
            // bubble colour tells at a glance.
            isMine: true,
            status: MessageStatus.read,
          ),
        );
    return id;
  }
}

final savedMessagesControllerProvider = Provider<SavedMessagesController>(
  SavedMessagesController.new,
);

/// The folder saved attachments are written to.
///
/// A provider rather than a call because resolving it needs a platform to
/// answer — which a test does not have, and a test of "the note kept the file"
/// should not need one.
final savedNotesDirectoryProvider = FutureProvider<Directory>((ref) async {
  final dir = await getApplicationDocumentsDirectory();
  return Directory('${dir.path}${Platform.pathSeparator}cubechat-saved');
});
