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
    this.isReachableViaMesh = false,
    this.isFavorite = false,
    this.isVerified = false,
  });

  final String id;
  final String peerId;
  final String peerName;
  final String lastMessage;
  final DateTime lastTime;
  final int unreadCount;
  final bool isMesh;
  final bool isOnline;

  /// True when there's no direct BLE session but we've received a peer
  /// announcement recently — i.e. the peer is reachable via one or more
  /// mesh hops. Used by the chat list to label the tile "via mesh".
  final bool isReachableViaMesh;

  final bool isFavorite;
  final bool isVerified;
}
