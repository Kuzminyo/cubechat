import 'package:flutter/foundation.dart';

enum MessageStatus { sending, delivered, read, failed }

/// What kind of payload this message carries. Media messages keep their raw
/// bytes on disk (see [Message.mediaPath]) and use [text] only for an
/// optional caption / mime label shown in the bubble.
enum MessageKind { text, image, audio }

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
    this.audioPath,
    this.audioMime,
    this.audioDurationMs,
    this.forwardSecret = false,
  });

  final String id;
  final String chatId;
  final String text;
  final DateTime sentAt;
  final bool isMine;
  final MessageStatus status;

  final MessageKind kind;

  /// True when this message was encrypted with a per-message forward-secret
  /// key (X3DH), as opposed to the long-term-key SealedBox path. Surfaced in
  /// the bubble as a small shield so the user can see the stronger guarantee.
  final bool forwardSecret;

  // Image payload (M5.4).
  final String? imagePath;
  final String? imageMime;

  // Audio payload (voice messages).
  final String? audioPath;
  final String? audioMime;
  final int? audioDurationMs;

  Message copyWith({
    MessageStatus? status,
    String? text,
    String? imagePath,
    String? audioPath,
    int? audioDurationMs,
    bool? forwardSecret,
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
      audioPath: audioPath ?? this.audioPath,
      audioMime: audioMime,
      audioDurationMs: audioDurationMs ?? this.audioDurationMs,
      forwardSecret: forwardSecret ?? this.forwardSecret,
    );
  }
}
