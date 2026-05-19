import 'package:flutter/foundation.dart';

enum MessageStatus { sending, delivered, read, failed }

/// What kind of payload this message carries. Media messages keep their raw
/// bytes on disk (see [Message.mediaPath]) and use [text] only for an
/// optional caption / mime label shown in the bubble.
enum MessageKind { text, image, audio, video }

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
    this.videoPath,
    this.videoMime,
    this.videoDurationMs,
  });

  final String id;
  final String chatId;
  final String text;
  final DateTime sentAt;
  final bool isMine;
  final MessageStatus status;

  final MessageKind kind;

  // Image payload (M5.4).
  final String? imagePath;
  final String? imageMime;

  // Audio payload (voice messages).
  final String? audioPath;
  final String? audioMime;
  final int? audioDurationMs;

  // Video payload (circle clips).
  final String? videoPath;
  final String? videoMime;
  final int? videoDurationMs;

  Message copyWith({
    MessageStatus? status,
    String? text,
    String? imagePath,
    String? audioPath,
    int? audioDurationMs,
    String? videoPath,
    int? videoDurationMs,
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
      videoPath: videoPath ?? this.videoPath,
      videoMime: videoMime,
      videoDurationMs: videoDurationMs ?? this.videoDurationMs,
    );
  }
}
