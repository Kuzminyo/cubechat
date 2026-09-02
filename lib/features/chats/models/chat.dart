import 'package:flutter/foundation.dart';

import '../../chat/models/message.dart';

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
    this.outgoingStatus,
  });

  final String id;
  final String peerId;
  final String peerName;
  final String lastMessage;
  final DateTime lastTime;
  final int unreadCount;
  final bool isMesh;
  /// Presence is deliberately absent.
  ///
  /// It lived here, computed for every row by the provider that builds the
  /// list, which made a beacon about one person recompute all of it — twelve
  /// watched sources, a sort and a preview per row. Ask
  /// [peerOnlineProvider] for one person instead; a row that watches its own
  /// peer repaints alone.

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

  /// How the last message in this conversation got on — but only when it is
  /// ours. Null when the last word was theirs, when there is nothing here yet,
  /// or while a draft is what the row is previewing: a tick beside somebody
  /// else's message would be claiming they had read their own, and a tick on an
  /// unsent draft would be claiming it had gone.
  ///
  /// This is the answer to "did that arrive?" without opening the chat, which
  /// is the one thing a list of conversations was not saying.
  final MessageStatus? outgoingStatus;

  bool get autoDeletes => autoDeleteSeconds > 0;

  /// Value equality, so a rebuild that produces the same rows is not a change.
  ///
  /// [Chat] is derived, not stored: `allChatsProvider` assembles it fresh from
  /// thirteen watched sources every time any one of them moves. Without this
  /// every assembly produced objects that were new *by identity*, Riverpod
  /// compared them by identity, found them different, and woke every watcher —
  /// the chats list and, through the providers they share, the open
  /// conversation too.
  ///
  /// Measured before it existed: one frame of 43.2 ms build against 1.6 ms
  /// raster, with `chats x53, chat x53` beside it. The matching counts are the
  /// tell — two screens rebuilding the same number of times are being woken by
  /// one source, not by their own business.
  ///
  /// Every field is in here on purpose. A row's unread count, its tick, its
  /// pin, its preview: leave one out and the list stops updating when that one
  /// changes, which is a far worse bug than the one being fixed and would not
  /// show up until somebody noticed a stale badge.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Chat &&
          other.id == id &&
          other.peerId == peerId &&
          other.peerName == peerName &&
          other.lastMessage == lastMessage &&
          other.lastTime == lastTime &&
          other.unreadCount == unreadCount &&
          other.isMesh == isMesh &&
          other.isReachableViaMesh == isReachableViaMesh &&
          other.isFavorite == isFavorite &&
          other.isPinned == isPinned &&
          other.isVerified == isVerified &&
          other.signKeyRotated == signKeyRotated &&
          other.isChannel == isChannel &&
          other.isDraft == isDraft &&
          other.isMuted == isMuted &&
          other.autoDeleteSeconds == autoDeleteSeconds &&
          other.pinRank == pinRank &&
          other.outgoingStatus == outgoingStatus;

  @override
  int get hashCode => Object.hash(
        id,
        peerId,
        peerName,
        lastMessage,
        lastTime,
        unreadCount,
        isMesh,
        isReachableViaMesh,
        isFavorite,
        isPinned,
        isVerified,
        signKeyRotated,
        isChannel,
        isDraft,
        isMuted,
        autoDeleteSeconds,
        pinRank,
        outgoingStatus,
      );
}
