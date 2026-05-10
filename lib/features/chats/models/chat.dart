import 'package:flutter/foundation.dart';

@immutable
class Chat {
  const Chat({
    required this.id,
    required this.peerId,
    required this.peerName,
    required this.lastMessage,
    required this.lastTime,
    required this.unreadCount,
    required this.isMesh,
    required this.isOnline,
    this.isFavorite = false,
  });

  final String id;
  final String peerId;
  final String peerName;
  final String lastMessage;
  final DateTime lastTime;
  final int unreadCount;
  final bool isMesh;
  final bool isOnline;
  final bool isFavorite;
}
