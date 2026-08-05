import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/identity/anon_name.dart';
import '../../../core/identity/wipe_service.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/transport/chat_session_manager.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/widgets/appear_animation.dart';
import '../../../core/widgets/context_popup.dart';
import '../../../core/widgets/cube_logo.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../../core/widgets/pill_button.dart';
import '../../../core/widgets/triple_tap_detector.dart';
import '../../../l10n/app_localizations.dart';
import '../../channels/data/channel_controller.dart';
import '../../chat/data/conversation_settings_controller.dart';
import '../../channels/data/channel_roster_controller.dart';
import '../../chat/data/drafts_controller.dart';
import '../../chat/data/messages_controller.dart';
import '../../chat/data/pinned_controller.dart';
import '../../chat/models/message.dart';
import '../../peers/data/contact_aliases_controller.dart';
import '../../peers/data/known_peers_controller.dart';
import '../../peers/data/peer_avatars_controller.dart';
import '../../peers/data/presence_controller.dart';
import '../data/chat_folders_controller.dart';
import '../data/favorites_controller.dart';
import '../data/read_markers_controller.dart';
import '../models/chat.dart';
import 'widgets/chat_tile.dart';
import '../../../core/widgets/glass_toast.dart';

/// Kept for the tests and callers that still name it; the list itself now
/// filters through [ChatFolder], which the user chooses rather than inherits.
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
  ref.watch(conversationSettingsControllerProvider);
  final known = ref.watch(knownPeersControllerProvider);
  final messagesByChat = ref.watch(messagesControllerProvider);
  final sessions = ref.watch(chatSessionManagerProvider);
  final channels = ref.watch(channelControllerProvider);
  final favorites = ref.watch(favoritesControllerProvider);
  final readMarkers = ref.watch(readMarkersControllerProvider);
  final presence = ref.watch(presenceControllerProvider);
  final drafts = ref.watch(draftsControllerProvider);
  final aliases = ref.watch(contactAliasesControllerProvider);

  final onlinePubkeys = <String>{
    for (final s in sessions.values)
      if (s.isEstablished && s.remotePubkeyHex != null) s.remotePubkeyHex!,
    // Peers who have the app open but are reachable only over the internet:
    // there is no session and no announcement, so a live beacon is the only
    // evidence they exist right now (see MessagingService.announcePresence).
    for (final e in presence.entries)
      if (e.value.online && e.value.isFresh) e.key,
  };

  final now = DateTime.now();
  final entries = known.values.map((peer) {
    final msgs = messagesByChat[peer.pubkeyHex] ?? const [];
    final last = msgs.isNotEmpty ? msgs.last : null;
    final unread = unreadMessageCount(msgs, readMarkers[peer.pubkeyHex]);
    final isOnline = onlinePubkeys.contains(peer.pubkeyHex);
    final isReachableViaMesh =
        !isOnline && now.difference(peer.lastSeen) <= _meshReachableWindow;
    final draft = drafts[peer.pubkeyHex];
    return Chat(
      id: peer.pubkeyHex,
      peerId: peer.pubkeyHex,
      peerName: contactDisplayName(
        alias: aliases[peer.pubkeyHex],
        rawBroadcastName: peer.displayName,
        pubkeyHex: peer.pubkeyHex,
      ),
      lastMessage: draft?.text ?? last?.text ?? 'Secured · Noise XX',
      lastTime: draft?.updatedAt ?? last?.sentAt ?? peer.lastSeen,
      unreadCount: unread,
      isMesh: true,
      isOnline: isOnline,
      isReachableViaMesh: isReachableViaMesh,
      isVerified: peer.isVerified,
      signKeyRotated: peer.hasUnacknowledgedRotation,
      isFavorite: favorites.contains(peer.pubkeyHex),
      isDraft: draft != null,
    );
  }).toList();

  // Group channels sit in the same list. They have no online/verified state —
  // membership is just holding the key. Last-message preview prefixes the
  // author for readability since a channel bucket mixes senders.
  for (final ch in channels.values) {
    final msgs = messagesByChat[ch.name] ?? const [];
    final last = msgs.isNotEmpty ? msgs.last : null;
    final unread = unreadMessageCount(msgs, readMarkers[ch.name]);
    final draft = drafts[ch.name];
    final preview = draft?.text ??
        (last == null
            ? 'Group channel'
            : (!last.isMine && last.authorName != null
                ? '${last.authorName}: ${last.text}'
                : last.text));
    entries.add(Chat(
      id: ch.name,
      peerId: ch.name,
      peerName: ch.name,
      lastMessage: preview,
      lastTime: draft?.updatedAt ?? last?.sentAt ?? ch.joinedAt,
      unreadCount: unread,
      isMesh: true,
      isOnline: false,
      isChannel: true,
      isFavorite: favorites.contains(ch.name),
      isDraft: draft != null,
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
    final query = ref.watch(chatsQueryProvider).toLowerCase();
    final all = ref.watch(chatsProvider);
    final folders = ref.watch(chatFoldersControllerProvider);
    final selected = ref.watch(selectedFolderProvider);
    // A folder that was switched off while it was the one being shown would
    // otherwise leave the list filtered by something with no pill on screen.
    final folder = selected != null && folders.contains(selected) ? selected : null;

    final filtered = all.where((c) {
      if (folder != null && !folder.matches(c)) return false;
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
                      _ChatsOverflowMenu(
                        onAddContact: () => context.push('/contact'),
                        onNewChannel: () =>
                            showNewChannelDialog(context, ref, t),
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
              // Looks like a field, behaves like a button. Typing happens on
              // the search screen, which has room to offer who you talk to and
              // who you last looked up — neither of which fits above a list
              // that is already full of chats.
              child: _SearchField(
                onTap: () => context.push('/search'),
                hint: t.chatsSearchHint,
              ),
            ),
          ),
          // Only once there is something in it. An empty folder row would be a
          // permanent strip of chrome between the search field and the first
          // conversation, on the screen that opens the app.
          if (folders.isNotEmpty)
            SliverToBoxAdapter(
              child: SizedBox(
                height: 56,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                  children: [
                    PillButton(
                      label: t.chatsFilterAll,
                      active: folder == null,
                      onTap: () =>
                          ref.read(selectedFolderProvider.notifier).state = null,
                    ),
                    for (final f in folders) ...[
                      const SizedBox(width: 8),
                      PillButton(
                        label: folderLabel(t, f),
                        active: folder == f,
                        onTap: () =>
                            ref.read(selectedFolderProvider.notifier).state = f,
                      ),
                    ],
                    const SizedBox(width: 8),
                    // The way back to the folder screen from the row itself —
                    // the menu is the other way in, and neither is discoverable
                    // from the other.
                    PillButton(
                      label: '+',
                      onTap: () => context.push('/folders'),
                    ),
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
              sliver: AppearOnce(
                builder: (context, animate) => SliverList.separated(
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final chat = filtered[i];
                    return AppearAnimation(
                      enabled: animate,
                      delay: AppearAnimation.stagger(i),
                      // Each row is its own levitating pane of smoked glass —
                      // the nav bar's treatment — so the list reads as separate
                      // floating islands over the aurora, not cards on a plate.
                      //
                      // Unblurred: the aurora behind is already a soft gradient,
                      // and a backdrop filter per row is a full blur pass per row
                      // per frame. See [FloatingGlass.blur].
                      child: FloatingGlass(
                        blur: false,
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
            ),
        ],
      ),
    );
  }
}

/// The search affordance on the Chats tab: a field to look at, a button to
/// press. Tapping it opens [ChatSearchScreen] rather than raising a keyboard
/// here — see the call site.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.onTap, required this.hint});

  final VoidCallback onTap;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return FloatingGlass(
      blur: false,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      borderRadius: 14,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Icon(Icons.search, size: 18, color: AppColors.textOnGlassFaint),
            const SizedBox(width: 12),
            Text(
              hint,
              style: TextStyle(
                color: AppColors.textOnGlassFaint,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One name per folder, so the pill in the row and the row on the folder screen
/// cannot drift apart.
String folderLabel(AppLocalizations t, ChatFolder folder) => switch (folder) {
      ChatFolder.unread => t.chatsFilterUnread,
      ChatFolder.direct => t.chatsFolderDirect,
      ChatFolder.channels => t.chatsFolderChannels,
      ChatFolder.favorites => t.chatsFilterFavorites,
      ChatFolder.online => t.chatsFolderOnline,
    };

IconData folderIcon(ChatFolder folder) => switch (folder) {
      ChatFolder.unread => Icons.mark_chat_unread_outlined,
      ChatFolder.direct => Icons.person_outline,
      ChatFolder.channels => Icons.campaign_rounded,
      ChatFolder.favorites => Icons.star_rounded,
      ChatFolder.online => Icons.podcasts,
    };

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
        side: BorderSide(color: AppColors.glass(0.15)),
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

  // Retracting only makes sense 1:1 and only for messages we sent: the wire
  // format can withdraw our own, and nothing can compel the other side to drop
  // theirs. Offering the choice on a channel, or when we have nothing of our
  // own in the thread, would promise more than it delivers.
  final retractable = chat.isChannel
      ? const <Message>[]
      : (ref.read(messagesControllerProvider)[chat.id] ?? const <Message>[])
          .where((m) => m.isMine && m.wireId != null)
          .toList();

  var alsoForThem = false;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        backgroundColor: AppColors.bgTop,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: AppColors.glass(0.15)),
        ),
        title: Text(
          t.chatsDeleteTitle,
          style: TextStyle(
            color: AppColors.textOnGlass,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              chat.isChannel ? t.chatsDeleteChannelHint : t.chatsDeletePeerHint,
              style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
            ),
            if (retractable.isNotEmpty) ...[
              const SizedBox(height: 6),
              CheckboxListTile(
                value: alsoForThem,
                onChanged: (v) =>
                    setDialogState(() => alsoForThem = v ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                activeColor: AppColors.brandPrimary,
                dense: true,
                title: Text(
                  t.chatsDeleteForThemToo,
                  style:
                      TextStyle(color: AppColors.textOnGlass, fontSize: 13.5),
                ),
                subtitle: Text(
                  t.chatsDeleteForThemHint,
                  style:
                      TextStyle(color: AppColors.textOnGlassDim, fontSize: 11),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.cancel,
                style: TextStyle(color: AppColors.textOnGlassDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.chatsActionDelete,
                style: const TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    ),
  );
  if (confirmed != true) return;

  // Retract before the local wipe: sendDeleteForEveryone resolves each target
  // against the stored message, so clearing first would leave nothing to send.
  if (alsoForThem) {
    final messaging = ref.read(messagingServiceProvider);
    for (final m in retractable) {
      await messaging.sendDeleteForEveryone(chat.id, m.wireId!);
    }
  }

  await ref.read(messagesControllerProvider.notifier).clearForChat(chat.id);
  await ref.read(favoritesControllerProvider.notifier).forget(chat.id);
  await ref.read(readMarkersControllerProvider.notifier).forget(chat.id);
  await ref.read(pinnedControllerProvider.notifier).forget(chat.id);
  await ref.read(draftsControllerProvider.notifier).clear(chat.id);
  if (chat.isChannel) {
    // Leaving forgets the key; without it the channel's broadcasts become
    // unreadable noise we simply relay.
    await ref.read(channelControllerProvider.notifier).leave(chat.id);
    await ref.read(channelRosterControllerProvider.notifier).forget(chat.id);
  } else {
    // Forget the roster entry too, otherwise the tile reappears empty.
    await ref.read(knownPeersControllerProvider.notifier).forget(chat.id);
    await ref.read(peerAvatarsControllerProvider.notifier).forget(chat.id);
  }
}

/// The two ways to start something new, behind one overflow control.
///
/// They were a pair of icon buttons in the header, which put two competing
/// affordances next to the title and still would not have had room for a third.
/// Both are the same kind of act — "begin a conversation" — so they belong in
/// one list rather than side by side, and the header gets its width back.
class _ChatsOverflowMenu extends StatelessWidget {
  const _ChatsOverflowMenu({
    required this.onAddContact,
    required this.onNewChannel,
  });

  final VoidCallback onAddContact;
  final VoidCallback onNewChannel;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return PopupMenuButton<_ChatsMenuAction>(
      icon: Icon(Icons.more_vert, color: AppColors.brandPrimary),
      tooltip: t.chatsMenuTooltip,
      color: AppColors.bgTop,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AppColors.glass(0.15)),
      ),
      position: PopupMenuPosition.under,
      popUpAnimationStyle: glassMenuMotion,
      onSelected: (action) => switch (action) {
        _ChatsMenuAction.saved => context.push('/saved'),
        _ChatsMenuAction.folders => context.push('/folders'),
        _ChatsMenuAction.addContact => onAddContact(),
        _ChatsMenuAction.newChannel => onNewChannel(),
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: _ChatsMenuAction.saved,
          child: _MenuRow(
            icon: Icons.bookmark_border_rounded,
            label: t.savedTitle,
          ),
        ),
        PopupMenuItem(
          value: _ChatsMenuAction.folders,
          child: _MenuRow(
            icon: Icons.folder_outlined,
            label: t.chatsFoldersTitle,
          ),
        ),
        PopupMenuItem(
          value: _ChatsMenuAction.addContact,
          child: _MenuRow(
            icon: Icons.person_add_alt,
            label: t.chatsMenuAddContact,
          ),
        ),
        PopupMenuItem(
          value: _ChatsMenuAction.newChannel,
          child: _MenuRow(
            icon: Icons.group_add_outlined,
            label: t.chatsMenuNewChannel,
          ),
        ),
      ],
    );
  }
}

enum _ChatsMenuAction { saved, folders, addContact, newChannel }

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppColors.brandPrimary),
        const SizedBox(width: 12),
        Text(
          label,
          style: TextStyle(color: AppColors.textOnGlass, fontSize: 14),
        ),
      ],
    );
  }
}

/// Prompt for a channel name + optional password, join it, and open it.
/// Joining is local — deriving the shared key makes you a member the moment a
/// matching-key message arrives on the mesh.
/// Public because the Contacts screen offers the same action from its own
/// header — one dialog, so the two entry points cannot drift apart.
Future<void> showNewChannelDialog(
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
        focusedBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: AppColors.brandPrimary),
        ),
      );

  final joined = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.bgTop,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: AppColors.glass(0.15)),
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
              style: TextStyle(color: AppColors.brandPrimary)),
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
