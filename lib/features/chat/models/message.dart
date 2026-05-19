import 'package:flutter/foundation.dart';

enum MessageStatus { sending, delivered, read, failed }

/// What kind of payload this message carries. Image messages keep their raw
/// bytes on disk (see [Message.imagePath]) and use [text] only for the
/// optional caption / mime label shown in the bubble.
enum MessageKind { text, image }

@immutable
class Message {
  const Message({
    required this.id,
    required this.chatId,
    required this.text,
    required this.sentAt,
    required this.isMine,
    this.status = MessageStatus.delivered,
    this.kind = MessageKind.text,
    this.imagePath,
    this.imageMime,
  });

  final String id;
  final String chatId;
  final String text;
  final DateTime sentAt;
  final bool isMine;
  final MessageStatus status;

  /// Text vs image; defaults to text so existing call sites stay unchanged.
  final MessageKind kind;

  /// Absolute filesystem path to the decoded image bytes — populated for
  /// image messages once all chunks have been reassembled (incoming) or
  /// once the picker has handed us a file (outgoing).
  final String? imagePath;

  /// MIME type advertised in the image chunk header (e.g. `image/jpeg`).
  final String? imageMime;

  Message copyWith({
    MessageStatus? status,
    String? text,
    String? imagePath,
  }) {
    return Message(
      id: id,
      chatId: chatId,
      text: text ?? this.text,
      sentAt: sentAt,
      isMine: isMine,
      status: status ?? this.status,
      kind: kind,
      imagePath: imagePath ?? this.imagePath,
      imageMime: imageMime,
    );
  }
}
