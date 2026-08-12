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
    this.isPinned = false,
    this.isVerified = false,
    this.signKeyRotated = false,
    this.isChannel = false,
    this.isDraft = false,
    this.isMuted = false,
    this.autoDeleteSeconds = 0,
    this.pinRank = -1,
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
  final bool isPinned;
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

  /// True when [lastMessage] is the unsent composer text for this chat.
  final bool isDraft;

  /// Messages from this conversation arrive without a sound. Worth a mark in
  /// the list: silence is otherwise indistinguishable from nobody writing, and
  /// the switch that caused it lives two screens away.
  final bool isMuted;

  /// How long a message survives here, in seconds; zero means it is kept. The
  /// list only cares whether the timer is on — see [autoDeletes] — but the
  /// period is carried so a row could say how long without asking again.
  final int autoDeleteSeconds;

  /// Where this chat sits among the pinned ones, or -1 when it is not pinned.
  /// The user drags this order; without it pinned rows re-sorted by recency and
  /// swapped places on their own.
  final int pinRank;

  bool get autoDeletes => autoDeleteSeconds > 0;
}
