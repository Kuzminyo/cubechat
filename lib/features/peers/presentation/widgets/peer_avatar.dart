import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/identity_avatar.dart';
import '../../../channels/data/channel_avatars_controller.dart';
import '../../../chats/data/saved_messages.dart';
import '../../data/known_peers_controller.dart';
import '../../data/peer_avatars_controller.dart';

/// Somebody else's avatar: their picture if we hold it, the generated identity
/// gradient if we don't.
///
/// A thin [ConsumerWidget] around [IdentityAvatar] rather than an extra
/// parameter threaded through every row, tile and header that draws a peer —
/// those are plain [StatelessWidget]s in six different features, and each would
/// have had to learn where avatars are cached and rebuild when one arrives. Here
/// the lookup and the rebuild live in one place, and a picture that lands mid-
/// scroll simply appears.
///
/// [peerId] is the peer's pubkey hex — the same key the cache and the roster
/// use. A raw BLE device id just misses, which is the wanted answer: it has no
/// face.
///
/// A channel id (`#name`) is looked up in the *channel* picture box instead.
/// Rooms keep their pictures apart from people's, for good reason — a room has
/// no key to sign its own avatar with, so the two are authenticated completely
/// differently — but this widget is the one place both are drawn, and it only
/// knew about one of them. The visible result was a channel picture set on one
/// phone showing up on the other only inside channel settings, with the chat
/// list still on the loudspeaker: the list was asking the wrong box, and always
/// missing.
class PeerAvatar extends ConsumerWidget {
  const PeerAvatar({
    super.key,
    required this.peerId,
    required this.label,
    required this.size,
    this.online = false,
    this.heroTag,
  });

  final String peerId;
  final String label;
  final double size;
  final bool online;
  final String? heroTag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watches the whole map: it holds a few KB per contact and changes only
    // when a picture arrives or is dropped, so selecting per-peer would buy
    // nothing but indirection.
    final isChannel = peerId.startsWith('#');
    // A blocked person keeps their picture in storage and loses it on screen.
    // Blocking is the one decision the app makes visible everywhere, and a
    // face smiling out of a list you blocked them from is the opposite of what
    // was asked for. The generated gradient takes its place — the same one a
    // stranger gets, which is what they now are.
    final blocked = !isChannel &&
        (ref.watch(knownPeersControllerProvider)[peerId]?.isBlocked ?? false);
    final bytes = blocked
        ? null
        : isChannel
            ? ref.watch(channelAvatarsControllerProvider)[peerId]
            : ref.watch(peerAvatarsControllerProvider)[peerId];
    return IdentityAvatar(
      seed: peerId,
      label: label,
      size: size,
      online: online,
      heroTag: heroTag,
      imageBytes: bytes,
      // Two chats in the list are not somebody. Saved notes get a bookmark —
      // the mark every messenger uses for the same thing — and a channel gets
      // the loudspeaker it already wears in Contacts. Both used to fall back
      // to initials, which for a channel meant a circle containing "#": the
      // punctuation its own id starts with, and the least informative
      // character in the name.
      mark: isSavedChat(peerId)
          ? Icons.bookmark_rounded
          : isChannel
              ? Icons.campaign_rounded
              : null,
    );
  }
}
