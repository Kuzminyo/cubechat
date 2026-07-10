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
    this.signKeyRotated = false,
    this.isChannel = false,
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

  /// True when the peer's Ed25519 signing key was rotated after our last
  /// out-of-band verification (or there was no verification yet at all
  /// and a rotation has been seen). The chat tile renders a warning
  /// chip; tapping the tile takes the user back to the verification
  /// screen so they can re-confirm the new fingerprint.
  final bool signKeyRotated;

  /// True when this entry is a shared-key group channel (id starts with `#`)
  /// rather than a 1:1 peer conversation. Channels have no online/verified
  /// state — anyone with the key is a member.
  final bool isChannel;
}
