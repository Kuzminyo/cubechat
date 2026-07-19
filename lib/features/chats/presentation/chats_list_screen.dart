import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/identity/anon_name.dart';
import '../../../core/identity/wipe_service.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/transport/chat_session_manager.dart';
import '../../../core/widgets/appear_animation.dart';
import '../../../core/widgets/context_popup.dart';
import '../../../core/widgets/cube_logo.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../../core/widgets/pill_button.dart';
import '../../../core/widgets/triple_tap_detector.dart';
import '../../../l10n/app_localizations.dart';
import '../../channels/data/channel_controller.dart';
import '../../chat/data/messages_controller.dart';
import '../../chat/models/message.dart';
import '../../peers/data/known_peers_controller.dart';
import '../data/favorites_controller.dart';
import '../data/read_markers_controller.dart';
import '../models/chat.dart';
import 'widgets/chat_tile.dart';
import '../../../core/widgets/glass_toast.dart';

enum ChatsFilter { all, unread, mesh, favorites }

/// Location for a chat list entry. Channels route by bare name — their id's
/// leading `#` is a URL fragment delimiter and can't live in a path.
String routeForChat(Chat chat) => chat.isChannel
    ? channelRoute(chat.peerId)
    : '/chat/${Uri.encodeComponent(chat.peerId)}'
        '?name=${Uri.encodeQueryComponent(chat.peerName)}';

/// [name] is the channel's chat id, e.g. `#ios-team`.
String channelRoute(String name) =>
    '/channel/${Uri.encodeComponent(name.replaceFirst('#', ''))}';

final chatsFilterProvider = StateProvider<ChatsFilter>((_) => ChatsFilter.all);
final chatsQueryProvider = StateProvider<String>((_) => '');

/// Real chat list — one entry per **authenticated peer ever seen**, keyed by
/// the peer's static pubkey (stable across BLE Privacy address rotation).
/// The entry sticks around in the list after the peer disconnects, so the
/// user can revisit the conversation and see history.
///
/// "Online" is derived from whether any live ChatSessionManager session has
/// the same pubkey — i.e. a transport handshake is currently up.
/// A peer counts as "reachable via mesh" if their lastSeen (last
/// announcement we received about them) is within this window. Tied to
/// the announcement cadence (M3.C, 60s) — give it a few cycles of slack
/// so a missed beacon doesn't make the tile flicker.
const _meshReachableWindow = Duration(minutes: 5);

/// Count of inbound messages the user hasn't seen yet: everything not-mine that
/// arrived after the chat's read marker. With no marker (never opened), every
/// inbound message is unread — opening the chat sets the marker and clears it.
/// Public so the counting rule can be unit-tested without a Hive-backed store.
int unreadMessageCount(List<Message> msgs, DateTime? lastReadAt) {
  if (lastReadAt == null) return msgs.where((m) => !m.isMine).length;
  return msgs.where((m) => !m.isMine && m.sentAt.isAfter(lastReadAt)).length;
}

final chatsProvider = Provider<List<Chat>>((ref) {
  final known = ref.watch(knownPeersControllerProvider);
  final messagesByChat = ref.watch(messagesControllerProvider);
  final sessions = ref.watch(chatSessionManagerProvider);
  final channels = ref.watch(channelControllerProvider);
  final favorites = ref.watch(favoritesControllerProvider);
  final readMarkers = ref.watch(readMarkersControllerProvider);

  final onlinePubkeys = <String>{
    for (final s in sessions.values)
      if (s.isEstablished && s.remotePubkeyHex != null) s.remotePubkeyHex!,
  };

  final now = DateTime.now();
  final entries = known.values.map((peer) {
    final msgs = messagesByChat[peer.pubkeyHex] ?? const [];
    final last = msgs.isNotEmpty ? msgs.last : null;
    final unread = unreadMessageCount(msgs, readMarkers[peer.pubkeyHex]);
    final isOnline = onlinePubkeys.contains(peer.pubkeyHex);
    final isReachableViaMesh =
        !isOnline && now.difference(peer.lastSeen) <= _meshReachableWindow;
    return Chat(
      id: peer.pubkeyHex,
      peerId: peer.pubkeyHex,
      peerName: displayNameForPeer(peer.displayName, peer.pubkeyHex),
      lastMessage: last?.text ?? 'Secured · Noise XX',
      lastTime: last?.sentAt ?? peer.lastSeen,
      unreadCount: unread,
      isMesh: true,
      isOnline: isOnline,
      isReachableViaMesh: isReachableViaMesh,
      isVerified: peer.isVerified,
      signKeyRotated: peer.hasUnacknowledgedRotation,
      isFavorite: favorites.contains(peer.pubkeyHex),
    );
  }).toList();

  // Group channels sit in the same list. They have no online/verified state —
  // membership is just holding the key. Last-message preview prefixes the
  // author for readability since a channel bucket mixes senders.
  for (final ch in channels.values) {
    final msgs = messagesByChat[ch.name] ?? const [];
    final last = msgs.isNotEmpty ? msgs.last : null;
    final unread = unreadMessageCount(msgs, readMarkers[ch.name]);
    final preview = last == null
        ? 'Group channel'
        : (!last.isMine && last.authorName != null
            ? '${last.authorName}: ${last.text}'
            : last.text);
    entries.add(Chat(
      id: ch.name,
      peerId: ch.name,
      peerName: ch.name,
      lastMessage: preview,
      lastTime: last?.sentAt ?? ch.joinedAt,
      unreadCount: unread,
      isMesh: true,
      isOnline: false,
      isChannel: true,
      isFavorite: favorites.contains(ch.name),
    ));
  }

  // Favourites float to the top; within each group, most recent first.
  entries.sort((a, b) {
    if (a.isFavorite != b.isFavorite) return a.isFavorite ? -1 : 1;
    return b.lastTime.compareTo(a.lastTime);
  });
  return entries;
});

class ChatsListScreen extends ConsumerWidget {
  const ChatsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final filter = ref.watch(chatsFilterProvider);
    final query = ref.watch(chatsQueryProvider).toLowerCase();
    final all = ref.watch(chatsProvider);

    final filtered = all.where((c) {
      switch (filter) {
        case ChatsFilter.all:
          break;
        case ChatsFilter.unread:
          if (c.unreadCount == 0) return false;
        case ChatsFilter.mesh:
          if (!c.isMesh) return false;
        case ChatsFilter.favorites:
          if (!c.isFavorite) return false;
      }
      if (query.isEmpty) return true;
      return c.peerName.toLowerCase().contains(query) ||
          c.lastMessage.toLowerCase().contains(query);
    }).toList();

    return SafeArea(
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      TripleTapDetector(
                        onTripleTap: () => _confirmWipe(context, ref, t),
                        child: const CubeLogo(size: 32),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child:
                            Text(t.chatsTitle, style: AppTypography.display()),
                      ),
                      IconButton(
                        onPressed: () => _showNewChannelDialog(context, ref, t),
                        icon: Icon(Icons.group_add_outlined,
                            color: AppColors.brandPrimary),
                        tooltip: t.channelsNewTooltip,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    t.chatsSubtitle,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textOnGlassDim,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _SearchField(
                onChanged: (v) =>
                    ref.read(chatsQueryProvider.notifier).state = v,
                hint: t.chatsSearchHint,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 56,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                children: [
                  _FilterPill(
                      label: t.chatsFilterAll,
                      value: ChatsFilter.all,
                      current: filter,
                      ref: ref),
                  const SizedBox(width: 8),
                  _FilterPill(
                      label: t.chatsFilterUnread,
                      value: ChatsFilter.unread,
                      current: filter,
                      ref: ref),
                  const SizedBox(width: 8),
                  _FilterPill(
                      label: t.chatsFilterMesh,
                      value: ChatsFilter.mesh,
                      current: filter,
                      ref: ref),
                  const SizedBox(width: 8),
                  _FilterPill(
                      label: t.chatsFilterFavorites,
                      value: ChatsFilter.favorites,
                      current: filter,
                      ref: ref),
                ],
              ),
            ),
          ),
          if (filtered.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child:
                  _EmptyState(title: t.chatsEmptyTitle, hint: t.chatsEmptyHint),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 140),
              sliver: SliverList.separated(
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final chat = filtered[i];
                  return AppearAnimation(
                    delay: AppearAnimation.stagger(i),
                    // Each row is its own levitating pane of smoked glass —
                    // the nav bar's treatment — so the list reads as separate
                    // floating islands over the aurora, not cards on a plate.
                    child: FloatingGlass(
                      borderRadius: 18,
                      onTap: () => context.push(routeForChat(chat)),
                      onLongPressAt: (pos) =>
                          _showChatActions(context, ref, chat, t, pos),
                      child: ChatTile(chat: chat),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.onChanged, required this.hint});

  final ValueChanged<String> onChanged;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return FloatingGlass(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      borderRadius: 14,
      child: TextField(
        onChanged: onChanged,
        cursorColor: AppColors.brandPrimary,
        style: TextStyle(color: AppColors.textOnGlass, fontSize: 14),
        decoration: InputDecoration(
          icon: Icon(Icons.search, size: 18, color: AppColors.textOnGlassFaint),
          border: InputBorder.none,
          isCollapsed: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
          hintText: hint,
          hintStyle: TextStyle(color: AppColors.textOnGlassFaint, fontSize: 14),
        ),
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.label,
    required this.value,
    required this.current,
    required this.ref,
  });

  final String label;
  final ChatsFilter value;
  final ChatsFilter current;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    return PillButton(
      label: label,
      active: value == current,
      onTap: () => ref.read(chatsFilterProvider.notifier).state = value,
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.glassFill,
                border: Border.all(color: AppColors.glassBorder),
              ),
              child: Icon(Icons.chat_bubble_outline,
                  color: AppColors.textOnGlassDim, size: 28),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                color: AppColors.textOnGlass,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

/// Triple-tap on the cube logo lands here — the bitchat-style emergency
/// wipe gesture. We still ask for confirmation; the gesture is the secret
/// shortcut, not a way to skip the confirmation.
Future<void> _confirmWipe(
  BuildContext context,
  WidgetRef ref,
  AppLocalizations t,
) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.bgTop,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
      ),
      title: Text(
        t.profileEmergencyWipeConfirm,
        style: TextStyle(
          color: AppColors.textOnGlass,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: Text(
        t.profileEmergencyWipeConfirmHint,
        style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child:
              Text(t.cancel, style: TextStyle(color: AppColors.textOnGlassDim)),
        ),
        TextButton(
          onPressed: () async {
            await emergencyWipe(ref);
            if (!ctx.mounted) return;
            Navigator.of(ctx).pop();
          },
          child: Text(
            t.profileEmergencyWipeAction,
            style: const TextStyle(color: AppColors.danger),
          ),
        ),
      ],
    ),
  );
}

/// Long-press actions for one chat: star it, or delete it. A small popup
/// anchored at [pos], floating above the nav bar.
Future<void> _showChatActions(
  BuildContext context,
  WidgetRef ref,
  Chat chat,
  AppLocalizations t,
  Offset pos,
) async {
  final favorited = chat.isFavorite;

  final action = await showContextPopup<String>(
    context: context,
    globalPosition: pos,
    items: [
      PopupMenuItem<String>(
        value: 'favorite',
        height: 44,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(favorited ? Icons.star : Icons.star_border,
                size: 19, color: AppColors.brandPrimary),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                favorited ? t.chatsActionUnfavorite : t.chatsActionFavorite,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppColors.textOnGlass, fontSize: 14),
              ),
            ),
          ],
        ),
      ),
      PopupMenuItem<String>(
        value: 'delete',
        height: 44,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.delete_outline, size: 19, color: AppColors.danger),
            const SizedBox(width: 12),
            Flexible(
              child: Text(t.chatsActionDelete,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(color: AppColors.danger, fontSize: 14)),
            ),
          ],
        ),
      ),
    ],
  );

  if (action == 'favorite') {
    await ref.read(favoritesControllerProvider.notifier).toggle(chat.id);
    return;
  }
  if (action != 'delete' || !context.mounted) return;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.bgTop,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
      ),
      title: Text(
        t.chatsDeleteTitle,
        style: TextStyle(
          color: AppColors.textOnGlass,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: Text(
        chat.isChannel ? t.chatsDeleteChannelHint : t.chatsDeletePeerHint,
        style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child:
              Text(t.cancel, style: TextStyle(color: AppColors.textOnGlassDim)),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(t.chatsActionDelete,
              style: const TextStyle(color: AppColors.danger)),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  await ref.read(messagesControllerProvider.notifier).clearForChat(chat.id);
  await ref.read(favoritesControllerProvider.notifier).forget(chat.id);
  await ref.read(readMarkersControllerProvider.notifier).forget(chat.id);
  if (chat.isChannel) {
    // Leaving forgets the key; without it the channel's broadcasts become
    // unreadable noise we simply relay.
    await ref.read(channelControllerProvider.notifier).leave(chat.id);
  } else {
    // Forget the roster entry too, otherwise the tile reappears empty.
    await ref.read(knownPeersControllerProvider.notifier).forget(chat.id);
  }
}

/// Prompt for a channel name + optional password, join it, and open it.
/// Joining is local — deriving the shared key makes you a member the moment a
/// matching-key message arrives on the mesh.
Future<void> _showNewChannelDialog(
  BuildContext context,
  WidgetRef ref,
  AppLocalizations t,
) async {
  final nameCtrl = TextEditingController();
  final pwCtrl = TextEditingController();

  InputDecoration deco(String hint, {String? prefix}) => InputDecoration(
        hintText: hint,
        prefixText: prefix,
        prefixStyle: TextStyle(color: AppColors.textOnGlassDim),
        hintStyle: TextStyle(color: AppColors.textOnGlassFaint, fontSize: 14),
        enabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: AppColors.glassBorder),
        ),
        focusedBorder: const UnderlineInputBorder(
          borderSide: BorderSide(color: AppColors.brandPrimary),
        ),
      );

  final joined = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.bgTop,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
      ),
      title: Text(
        t.channelsNewTitle,
        style: TextStyle(
          color: AppColors.textOnGlass,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: nameCtrl,
            autofocus: true,
            cursorColor: AppColors.brandPrimary,
            style: TextStyle(color: AppColors.textOnGlass),
            decoration: deco(t.channelNameLabel, prefix: '#'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: pwCtrl,
            obscureText: true,
            cursorColor: AppColors.brandPrimary,
            style: TextStyle(color: AppColors.textOnGlass),
            decoration: deco(t.channelPasswordLabel),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child:
              Text(t.cancel, style: TextStyle(color: AppColors.textOnGlassDim)),
        ),
        TextButton(
          onPressed: () async {
            final name = nameCtrl.text.trim();
            if (name.isEmpty) return;
            try {
              final ch = await ref
                  .read(channelControllerProvider.notifier)
                  .join(name, password: pwCtrl.text);
              if (ctx.mounted) Navigator.of(ctx).pop(ch.name);
            } catch (_) {
              // The only reachable failure here is a name that wouldn't fit in
              // a channel invite — an empty one is already guarded above.
              if (!ctx.mounted) return;
              // Toast first: it goes to the root overlay, so it survives the
              // dialog closing underneath it. (This is what the captured
              // ScaffoldMessenger used to be for.)
              showGlassToast(ctx, t.channelNameTooLong, tone: ToastTone.danger);
              Navigator.of(ctx).pop();
            }
          },
          child: Text(t.channelJoinAction,
              style: const TextStyle(color: AppColors.brandPrimary)),
        ),
      ],
    ),
  );

  nameCtrl.dispose();
  pwCtrl.dispose();

  if (joined != null && context.mounted) {
    context.push(channelRoute(joined));
  }
}
