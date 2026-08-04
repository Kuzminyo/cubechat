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
  Future<void> saveImage(
    Uint8List bytes, {
    String mime = 'image/jpeg',
    String? caption,
  }) async {
    if (bytes.isEmpty) return;
    final file = await _store('.jpg');
    await file.writeAsBytes(bytes, flush: true);
    await _append(
      kind: MessageKind.image,
      text: caption ?? mime,
      imagePath: file.path,
      imageMime: mime,
    );
  }

  /// A file kept as a note, copied in so clearing the source changes nothing.
  Future<void> saveFile(
    File source, {
    required String fileName,
    required String mime,
  }) async {
    final safe = fileName.trim().isEmpty ? 'file' : fileName.trim();
    final dot = safe.lastIndexOf('.');
    final copy = await _store(dot < 0 ? '' : safe.substring(dot));
    await source.copy(copy.path);
    await _append(
      kind: MessageKind.file,
      text: mime,
      filePath: copy.path,
      fileName: safe,
      fileBytes: await copy.length(),
    );
  }

  /// A voice note to yourself.
  Future<void> saveVoice(
    File source, {
    required int durationMs,
    String mime = 'audio/aac',
  }) async {
    final copy = await _store('.m4a');
    await source.copy(copy.path);
    await _append(
      kind: MessageKind.audio,
      text: mime,
      audioPath: copy.path,
      audioMime: mime,
      audioDurationMs: durationMs,
    );
  }

  Future<void> _append({
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
    await _ref.read(messagesControllerProvider.notifier).append(
          savedChatId,
          Message(
            id: _uuid.v4(),
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
  }

  Future<void> saveText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _ref.read(messagesControllerProvider.notifier).append(
          savedChatId,
          Message(
            id: _uuid.v4(),
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
