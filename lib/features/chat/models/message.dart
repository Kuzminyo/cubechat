import 'package:flutter/foundation.dart';

enum MessageStatus { sending, delivered, read, failed }

@immutable
class Message {
  const Message({
    required this.id,
    required this.chatId,
    required this.text,
    required this.sentAt,
    required this.isMine,
    this.status = MessageStatus.delivered,
  });

  final String id;
  final String chatId;
  final String text;
  final DateTime sentAt;
  final bool isMine;
  final MessageStatus status;
}
