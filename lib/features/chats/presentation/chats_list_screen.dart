import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../../chat/data/message_visibility.dart';
import '../../chat/data/messages_controller.dart';
import '../../chat/data/pinned_controller.dart';
import '../../chat/models/message.dart';
import '../../../core/locale/locale_controller.dart';
import '../../chat/domain/message_preview.dart';
import '../../peers/data/contact_aliases_controller.dart';
import '../../peers/data/contact_removal.dart';
import '../../peers/data/known_peers_controller.dart';
import '../../peers/data/presence_controller.dart';
import '../data/chat_folders_controller.dart';
import '../data/chat_selection_controller.dart';
import '../data/favorites_controller.dart';
import '../data/hidden_chats_controller.dart';
import '../data/pinned_chats_controller.dart';
import '../data/read_markers_controller.dart';
import '../data/user_chat_folders_controller.dart';
import '../data/saved_messages.dart';
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
    : isSavedChat(chat.peerId)
        // Its own route, because the chat route's path parameter is a peer
        // pubkey and this conversation has no peer.
        ? '/saved'
        : '/chat/${Uri.encodeComponent(chat.peerId)}'
            '?name=${Uri.encodeQueryComponent(chat.peerName)}';

/// The notebook, as a row in the chat list.
///
/// It was reachable only from the overflow menu, which is a strange place for
/// the conversation somebody uses most often after their friends — every
/// messenger that has one of these puts it in the list. Built here rather than
/// added to [chatsProvider] because that list is also what Contacts, search
/// and the forward sheet read, and none of them should offer to forward
/// something to a notebook or list it as a person.
///
/// Null until there is something in it: an empty notebook advertising itself
/// at the top of an empty chat list is noise on the one screen a new install
/// has nothing on.
Chat? savedChatRow(WidgetRef ref, AppLocalizations t) {
  final messages = ref.watch(messagesControllerProvider)[savedChatId];
  if (messages == null || messages.isEmpty) return null;
  final last = lastVisibleMessage(messages);
  final pinned = ref.watch(pinnedChatsControllerProvider);
  final settings = ref.watch(conversationSettingsControllerProvider);
  return Chat(
    id: savedChatId,
    peerId: savedChatId,
    peerName: t.savedTitle,
    // A photo's `text` is its mime type and a sticker's is its marker, so what
    // a row shows is composed rather than copied — see [messagePreview].
    lastMessage: last == null ? '' : messagePreview(last, t),
    lastTime: last?.sentAt ?? messages.last.sentAt,
    unreadCount: 0,
    isMesh: false,
    isOnline: false,
    // A normal row in every other respect, so it pins and expires like one.
    isPinned: pinned.contains(savedChatId),
    pinRank: pinned.indexOf(savedChatId),
    autoDeleteSeconds: settings[savedChatId]?.autoDelete.seconds ?? 0,
  );
}

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

/// The sort key for a conversation nobody has said anything in. Older than any
/// real message, so those rows collect at the bottom of the list rather than
/// riding whatever last refreshed the peer's `lastSeen`.
final _neverSpoken = DateTime.fromMillisecondsSinceEpoch(0);

/// Count of inbound messages the user hasn't seen yet: everything not-mine that
/// arrived after the chat's read marker. With no marker (never opened), every
/// inbound message is unread — opening the chat sets the marker and clears it.
/// Public so the counting rule can be unit-tested without a Hive-backed store.
int unreadMessageCount(List<Message> msgs, DateTime? lastReadAt) {
  // Map beacons are excluded: nobody wrote them, nobody can read them, and a
  // badge counting them told the user there were forty new messages waiting in
  // a chat where nothing had been said all day.
  bool counts(Message m) => !m.isMine && !isMapBeaconMessage(m);
  if (lastReadAt == null) return msgs.where(counts).length;
  return msgs.where((m) => counts(m) && m.sentAt.isAfter(lastReadAt)).length;
}

/// Every conversation the app knows of, including ones whose history the user
/// deleted. [chatsProvider] is this list minus those.
///
/// The split exists because a deleted conversation is not a deleted person:
/// Contacts goes on listing them (see `contactChatsProvider`) while the chat
/// list does not, and both need the same Chat objects to do it.
/// Row order for the chat list, in one place because two lists sort by it.
///
/// Pinned first, and among the pinned by the order the user dragged them into —
/// not by recency. Recency is what a pin is for overriding: pinned rows used to
/// re-sort themselves every time somebody wrote, so the row a thumb was aiming
/// for had moved by the time it landed.
int compareChatRows(Chat a, Chat b) {
  if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
  if (a.isPinned && b.isPinned && a.pinRank != b.pinRank) {
    return a.pinRank.compareTo(b.pinRank);
  }
  return b.lastTime.compareTo(a.lastTime);
}

/// The tick a row shows, or nothing at all. See [Chat.outgoingStatus] for when
/// each of the three "nothing" cases applies.
MessageStatus? _outgoingStatus(Message? last, {required bool hasDraft}) {
  if (hasDraft || last == null || !last.isMine) return null;
  return last.status;
}

final allChatsProvider = Provider<List<Chat>>((ref) {
  // The row previews are words — "Photo", "Sticker" — so the list re-derives
  // when the language does.
  final t = lookupAppLocalizations(ref.watch(localeControllerProvider));
  final settings = ref.watch(conversationSettingsControllerProvider);
  final known = ref.watch(knownPeersControllerProvider);
  final messagesByChat = ref.watch(messagesControllerProvider);
  final sessions = ref.watch(chatSessionManagerProvider);
  final channels = ref.watch(channelControllerProvider);
  final favorites = ref.watch(favoritesControllerProvider);
  final pinnedChats = ref.watch(pinnedChatsControllerProvider);
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
    // Map beacons are not conversation, so they must not be what a tile says
    // the conversation last was. New ones never reach history at all; this
    // skips the ones an older build already filed there.
    final last = lastVisibleMessage(msgs);
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
      lastMessage: draft?.text ??
          (last == null ? 'Secured · Noise XX' : messagePreview(last, t)),
      // An empty conversation sinks instead of floating.
      //
      // It used to fall back to the peer's lastSeen, which every announcement
      // refreshes — so a chat whose history had just been cleared, by
      // auto-delete or by hand, jumped straight to the top of the list as the
      // most recent thing in it, with nothing in it. Nothing has been said
      // here, so it sorts as though nothing has: at the bottom, where it can
      // be found and does not push a live conversation down.
      lastTime: draft?.updatedAt ?? last?.sentAt ?? _neverSpoken,
      unreadCount: unread,
      isMesh: true,
      isOnline: isOnline,
      isReachableViaMesh: isReachableViaMesh,
      isVerified: peer.isVerified,
      signKeyRotated: peer.hasUnacknowledgedRotation,
      isFavorite: favorites.contains(peer.pubkeyHex),
      isPinned: pinnedChats.contains(peer.pubkeyHex),
      pinRank: pinnedChats.indexOf(peer.pubkeyHex),
      isDraft: draft != null,
      isMuted: peer.isMuted,
      autoDeleteSeconds: settings[peer.pubkeyHex]?.autoDelete.seconds ?? 0,
      outgoingStatus: _outgoingStatus(last, hasDraft: draft != null),
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
                ? '${last.authorName}: ${messagePreview(last, t)}'
                : messagePreview(last, t)));
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
      isPinned: pinnedChats.contains(ch.name),
      pinRank: pinnedChats.indexOf(ch.name),
      isDraft: draft != null,
      autoDeleteSeconds: settings[ch.name]?.autoDelete.seconds ?? 0,
      outgoingStatus: _outgoingStatus(last, hasDraft: draft != null),
    ));
  }

  // Only pinned chats float. Favourites are just marked as favourites and sort
  // like ordinary conversations; otherwise a starred chat looks like it is
  // pinned even when the user never pinned it.
  entries.sort(compareChatRows);
  return entries;
});

/// The conversations worth listing as conversations.
///
/// A deleted conversation keeps its contact but loses its tile — until there
/// is something in it again, which is the moment it stops being a deleted
/// conversation. Nothing has to remember to un-hide it.
final chatsProvider = Provider<List<Chat>>((ref) {
  final all = ref.watch(allChatsProvider);
  final hidden = ref.watch(hiddenChatsControllerProvider);
  if (hidden.isEmpty) return all;
  final messagesByChat = ref.watch(messagesControllerProvider);
  return all
      .where((chat) =>
          !hidden.contains(chat.id) ||
          (messagesByChat[chat.id]?.isNotEmpty ?? false))
      .toList();
});

class ChatsListScreen extends ConsumerWidget {
  const ChatsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final query = ref.watch(chatsQueryProvider).toLowerCase();
    final all = ref.watch(chatsProvider);
    final folders = ref.watch(chatFoldersControllerProvider);
    final userFolders = ref.watch(userChatFoldersControllerProvider);
    final selected = ref.watch(selectedFolderProvider);
    final selectedUserFolderId = ref.watch(selectedUserFolderProvider);
    // A folder that was switched off while it was the one being shown would
    // otherwise leave the list filtered by something with no pill on screen.
    final folder =
        selected != null && folders.contains(selected) ? selected : null;
    final userFolder = selectedUserFolderId == null
        ? null
        : ref
            .read(userChatFoldersControllerProvider.notifier)
            .byId(selectedUserFolderId);

    final selection = ref.watch(chatSelectionProvider);
    // The system back gesture means "undo the mode I am in" before it means
    // "leave the screen". Picking chats out is a mode, and on a phone where
    // back *is* a swipe there was no other way to say "never mind" without
    // finding the small × in the bar that had replaced the title.
    final selecting = selection.isNotEmpty;
    final saved = savedChatRow(ref, t);
    final filtered = [
      // An ordinary row, sorted by when it was last written in like every
      // other.
      if (saved != null &&
          folder == null &&
          userFolder == null &&
          (query.isEmpty || saved.peerName.toLowerCase().contains(query)))
        saved,
      ...all.where((c) {
        if (folder != null && !folder.matches(c)) return false;
        if (userFolder != null && !userFolder.contains(c.id)) return false;
        if (query.isEmpty) return true;
        return c.peerName.toLowerCase().contains(query) ||
            c.lastMessage.toLowerCase().contains(query);
      }),
    ]..sort(compareChatRows);
    return PopScope<void>(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selecting) {
          ref.read(chatSelectionProvider.notifier).clear();
        }
      },
      child: SafeArea(
        child: CustomScrollView(
          slivers: [
            if (selection.isNotEmpty)
              SliverPersistentHeader(
                pinned: true,
                delegate: _PinnedChatSelectionHeader(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                    child: _ChatSelectionBar(
                      key: const ValueKey('selection'),
                      selected: [
                        for (final chat in filtered)
                          if (selection.contains(chat.id)) chat,
                      ],
                    ),
                  ),
                ),
              )
            else
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
                            child: Text(
                              t.chatsTitle,
                              style: AppTypography.display(),
                            ),
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
            if (folders.isNotEmpty || userFolders.isNotEmpty)
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 56,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                    children: [
                      PillButton(
                        label: t.chatsFilterAll,
                        active: folder == null && userFolder == null,
                        onTap: () {
                          ref.read(selectedFolderProvider.notifier).state =
                              null;
                          ref.read(selectedUserFolderProvider.notifier).state =
                              null;
                        },
                      ),
                      for (final f in folders) ...[
                        const SizedBox(width: 8),
                        PillButton(
                          label: folderLabel(t, f),
                          active: folder == f,
                          onTap: () {
                            ref
                                .read(selectedUserFolderProvider.notifier)
                                .state = null;
                            ref.read(selectedFolderProvider.notifier).state = f;
                          },
                        ),
                      ],
                      for (final f in userFolders) ...[
                        const SizedBox(width: 8),
                        PillButton(
                          label: f.name,
                          active: userFolder?.id == f.id,
                          onTap: () {
                            ref.read(selectedFolderProvider.notifier).state =
                                null;
                            ref
                                .read(selectedUserFolderProvider.notifier)
                                .state = f.id;
                          },
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
                child: _EmptyState(
                    title: t.chatsEmptyTitle, hint: t.chatsEmptyHint),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 140),
                sliver: AppearOnce(
                  builder: (context, animate) => SliverReorderableList(
                    itemCount: filtered.length,
                    onReorderStart: (_) => HapticFeedback.selectionClick(),
                    // A click on the way down as well as on the way up: the drop
                    // is the half that changes something, and without it the row
                    // simply stops moving.
                    onReorderEnd: (_) => HapticFeedback.selectionClick(),
                    // The dragged row lifts instead of gaining the Material
                    // elevation the default draws, which on these glass cards
                    // arrives as a grey rectangle under the finger. The shadow
                    // grows with the lift so the row reads as picked up rather
                    // than as suddenly larger.
                    proxyDecorator: (child, index, animation) =>
                        AnimatedBuilder(
                      animation: animation,
                      child: child,
                      builder: (context, inner) {
                        final t =
                            Curves.easeOutCubic.transform(animation.value);
                        return Transform.scale(
                          scale: 1 + 0.04 * t,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(18),
                              boxShadow: [
                                BoxShadow(
                                  color:
                                      Colors.black.withValues(alpha: 0.38 * t),
                                  blurRadius: 24 * t,
                                  offset: Offset(0, 10 * t),
                                  spreadRadius: -8 * t,
                                ),
                              ],
                            ),
                            child: inner,
                          ),
                        );
                      },
                    ),
                    // Only the pinned block moves, and only within itself. A pin
                    // is the one row whose position somebody chose; everything
                    // below it is sorted by when it was last written in, and a
                    // list you can drag rows around in that then re-sorts itself
                    // is a list that ignores you.
                    onReorder: (oldIndex, newIndex) {
                      final pins = [
                        for (final chat in filtered)
                          if (chat.isPinned) chat.id,
                      ];
                      if (oldIndex >= pins.length) return;
                      if (newIndex > oldIndex) newIndex -= 1;
                      final target = newIndex.clamp(0, pins.length - 1);
                      if (target == oldIndex) return;
                      pins.insert(target, pins.removeAt(oldIndex));
                      ref
                          .read(pinnedChatsControllerProvider.notifier)
                          .reorderVisible(pins);
                    },
                    itemBuilder: (_, i) {
                      final chat = filtered[i];
                      final picked = selection.contains(chat.id);
                      return Padding(
                        key: ValueKey(chat.id),
                        // The gap rides with the row: a reorderable list has no
                        // separators to keep it out of the way of a drag.
                        padding: EdgeInsets.only(
                          bottom: i == filtered.length - 1 ? 0 : 8,
                        ),
                        child: AppearAnimation(
                          enabled: animate,
                          delay: AppearAnimation.stagger(i),
                          child: FloatingGlass(
                            blur: false,
                            borderRadius: 18,
                            // While anything is selected, a tap picks rather
                            // than opens — the same rule every list of this
                            // shape uses, and the only one that lets somebody
                            // select a second chat without the first one's chat
                            // opening on them.
                            onTap: () {
                              if (selection.isEmpty) {
                                context.push(routeForChat(chat));
                                return;
                              }
                              ref
                                  .read(chatSelectionProvider.notifier)
                                  .toggle(chat.id);
                            },
                            // Holding a row picks it out, and nothing else. A
                            // menu was tried here and taken back out: the hold is
                            // what puts the list into the mode where a pinned row
                            // grows its drag handle, so a popup on top of it took
                            // away the way to reorder pins. Every action lives in
                            // the bar the selection opens — including deleting
                            // the chat and deleting the person.
                            onLongPressAt: (_) => ref
                                .read(chatSelectionProvider.notifier)
                                .toggle(chat.id),
                            child: ChatTile(
                              chat: chat,
                              selected: picked,
                              // The grip appears when the list is held — the
                              // same gesture that starts a selection — and only
                              // on the rows that can move. Permanently visible it
                              // was a control on every pinned row of a list
                              // nobody is currently rearranging; and dragging is
                              // gated on it, so outside that mode a pinned row
                              // scrolls like any other instead of setting off a
                              // reorder under a thumb that meant to scroll.
                              reorderIndex:
                                  chat.isPinned && selection.isNotEmpty
                                      ? i
                                      : null,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PinnedChatSelectionHeader extends SliverPersistentHeaderDelegate {
  const _PinnedChatSelectionHeader({required this.child});

  static const double _height = 80;

  final Widget child;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.bgDeep.withValues(alpha: 0.97),
            AppColors.bgDeep.withValues(alpha: 0.74),
          ],
        ),
      ),
      child: child,
    );
  }

  @override
  bool shouldRebuild(_PinnedChatSelectionHeader oldDelegate) =>
      oldDelegate.child != child;
}

/// What the title row turns into while chats are picked out.
///
/// The quick actions are the ones worth reaching without a menu — pin, mute,
/// delete — and everything else lives behind the overflow, which is the same
/// list a single row used to open on a long press. Nothing here is destructive
/// without a confirmation of its own.
class _ChatSelectionBar extends ConsumerWidget {
  const _ChatSelectionBar({super.key, required this.selected});

  final List<Chat> selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final peers = ref.read(knownPeersControllerProvider.notifier);
    final pinned = ref.watch(pinnedChatsControllerProvider);
    // "Un-pin them" only when every one of them is pinned; a mixed selection
    // pins, which is the answer that leaves the set in a state somebody asked
    // for rather than half of one.
    final allPinned =
        selected.isNotEmpty && selected.every((c) => pinned.contains(c.id));
    final direct = selected.where((c) => !c.isChannel).toList();
    final allMuted =
        direct.isNotEmpty && direct.every((c) => peers.isMuted(c.id));

    return Row(
      children: [
        IconButton(
          icon: Icon(Icons.close_rounded, color: AppColors.textOnGlass),
          tooltip: t.cancel,
          onPressed: () => ref.read(chatSelectionProvider.notifier).clear(),
        ),
        Text(
          '${selected.length}',
          style: TextStyle(
            color: AppColors.textOnGlass,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const Spacer(),
        IconButton(
          icon: Icon(
            allPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
            color: AppColors.brandPrimary,
          ),
          tooltip: _chatText(context, uk: 'Закріпити', en: 'Pin'),
          onPressed: () async {
            final pins = ref.read(pinnedChatsControllerProvider.notifier);
            for (final chat in selected) {
              await (allPinned ? pins.unpin(chat.id) : pins.pin(chat.id));
            }
            ref.read(chatSelectionProvider.notifier).clear();
          },
        ),
        if (direct.isNotEmpty)
          IconButton(
            icon: Icon(
              allMuted
                  ? Icons.notifications_active_outlined
                  : Icons.notifications_off_outlined,
              color: AppColors.textOnGlass,
            ),
            tooltip: _chatText(context, uk: 'Без звуку', en: 'Mute'),
            onPressed: () async {
              for (final chat in direct) {
                await peers.setMuted(chat.id, !allMuted);
              }
              ref.read(chatSelectionProvider.notifier).clear();
            },
          ),
        IconButton(
          icon: Icon(Icons.delete_outline, color: AppColors.danger),
          tooltip: t.chatsActionDelete,
          onPressed: () async {
            final chats = [...selected];
            ref.read(chatSelectionProvider.notifier).clear();
            for (final chat in chats) {
              if (!context.mounted) return;
              await _confirmAndDeleteChat(context, ref, chat, t);
            }
          },
        ),
        _SelectionOverflow(selected: selected),
      ],
    );
  }
}

/// The rest of the menu, unchanged in content from the one a long press used
/// to open — it simply applies to everything picked out instead of to the row
/// under the finger.
class _SelectionOverflow extends ConsumerWidget {
  const _SelectionOverflow({required this.selected});

  final List<Chat> selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final single = selected.length == 1 ? selected.first : null;
    return IconButton(
      icon: Icon(Icons.more_vert, color: AppColors.textOnGlass),
      onPressed: () async {
        final box = context.findRenderObject() as RenderBox?;
        final origin = box == null
            ? Offset.zero
            : box.localToGlobal(box.size.center(Offset.zero));
        final action = await showContextPopup<String>(
          context: context,
          globalPosition: origin,
          items: [
            _chatMenuItem(
              'folder',
              Icons.folder_outlined,
              _chatText(context, uk: 'Додати в папку', en: 'Add to folder'),
            ),
            _chatMenuItem(
              'unread',
              Icons.mark_chat_unread_outlined,
              _chatText(
                context,
                uk: 'Позначити як непрочитане',
                en: 'Mark as unread',
              ),
            ),
            _chatMenuItem(
              'clear',
              Icons.cleaning_services_outlined,
              _chatText(
                context,
                uk: 'Очистити історію чату',
                en: 'Clear chat history',
              ),
            ),
            // One person at a time: blocking is about somebody, and a channel
            // has nobody to block.
            if (single != null && !single.isChannel)
              _chatMenuItem(
                'block',
                ref
                        .read(knownPeersControllerProvider.notifier)
                        .isBlocked(single.id)
                    ? Icons.lock_open_rounded
                    : Icons.block_rounded,
                ref
                        .read(knownPeersControllerProvider.notifier)
                        .isBlocked(single.id)
                    ? t.peerUnblock
                    : t.peerBlock,
                color: AppColors.danger,
              ),
            _chatMenuItem(
              'favorite',
              Icons.star_border,
              t.chatsActionFavorite,
              color: AppColors.brandPrimary,
            ),
            // Deleting the *person*, which the bin in the bar deliberately does
            // not do — that one empties the conversation and keeps the keys
            // that let it start again. One at a time, and never for a channel,
            // which has nobody to forget.
            if (single != null && !single.isChannel)
              _chatMenuItem(
                'forget',
                Icons.person_remove_outlined,
                t.contactProfileDelete,
                color: AppColors.danger,
              ),
          ],
        );
        if (action == null || !context.mounted) return;
        final chats = [...selected];
        switch (action) {
          case 'folder':
            for (final chat in chats) {
              if (!context.mounted) return;
              await _showAddToFolderDialog(context, ref, chat, t);
            }
          case 'unread':
            for (final chat in chats) {
              if (!context.mounted) return;
              await _markChatUnread(context, ref, chat);
            }
          case 'clear':
            for (final chat in chats) {
              if (!context.mounted) return;
              await _confirmAndClearHistory(context, ref, chat);
            }
          case 'block':
            if (single == null || !context.mounted) return;
            await _toggleBlocked(
              context,
              ref,
              single,
              blocked: ref
                  .read(knownPeersControllerProvider.notifier)
                  .isBlocked(single.id),
              t: t,
            );
          case 'favorite':
            final favorites = ref.read(favoritesControllerProvider.notifier);
            for (final chat in chats) {
              await favorites.toggle(chat.id);
            }
          case 'forget':
            if (single == null || !context.mounted) return;
            await _confirmAndForgetContact(context, ref, single, t);
        }
        ref.read(chatSelectionProvider.notifier).clear();
      },
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
            Expanded(
              child: Text(
                hint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.textOnGlassFaint,
                  fontSize: 14,
                ),
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

/// Delete the person, not just the conversation.
///
/// Next to "delete chat" on purpose, and spelled out in the dialog, because
/// the two are genuinely different and the difference is the thing people get
/// wrong: one empties a conversation and keeps the keys that let it start
/// again, the other throws the keys away.
Future<void> _confirmAndForgetContact(
  BuildContext context,
  WidgetRef ref,
  Chat chat,
  AppLocalizations t,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.bgTop,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: AppColors.glass(0.15)),
      ),
      title: Text(
        t.contactProfileDeleteTitle,
        style: TextStyle(
          color: AppColors.textOnGlass,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: Text(
        t.contactProfileDeleteMessage(chat.peerName),
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
          child: Text(
            t.contactProfileDelete,
            style: const TextStyle(color: AppColors.danger),
          ),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  await forgetContactEverywhere(ref, chat.id);
  if (!context.mounted) return;
  showGlassToast(
    context,
    t.contactProfileDelete,
    icon: Icons.person_remove_outlined,
    tone: ToastTone.success,
  );
}

PopupMenuItem<String> _chatMenuItem(
  String value,
  IconData icon,
  String label, {
  Color? color,
}) {
  final effectiveColor = color ?? AppColors.textOnGlass;
  return PopupMenuItem<String>(
    value: value,
    height: 44,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 19, color: effectiveColor),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: effectiveColor, fontSize: 14),
          ),
        ),
      ],
    ),
  );
}

String _chatText(
  BuildContext context, {
  required String uk,
  required String en,
}) =>
    Localizations.localeOf(context).languageCode == 'uk' ? uk : en;

Future<void> _showAddToFolderDialog(
  BuildContext context,
  WidgetRef ref,
  Chat chat,
  AppLocalizations t,
) async {
  final userFolders = ref.read(userChatFoldersControllerProvider);
  const createToken = '__create__';
  final picked = await showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      backgroundColor: AppColors.bgTop,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: AppColors.glass(0.15)),
      ),
      title: Text(
        _chatText(
          context,
          uk: '\u0414\u043e\u0434\u0430\u0442\u0438 \u0432 \u043f\u0430\u043f\u043a\u0443',
          en: 'Add to folder',
        ),
        style: TextStyle(
          color: AppColors.textOnGlass,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
      children: [
        for (final folder in userFolders)
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(folder.id),
            child: _MenuRow(icon: Icons.folder_outlined, label: folder.name),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(ctx).pop(createToken),
          child: _MenuRow(
            icon: Icons.create_new_folder_outlined,
            label: _chatText(
              context,
              uk: '\u041d\u043e\u0432\u0430 \u043f\u0430\u043f\u043a\u0430',
              en: 'New folder',
            ),
          ),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(
            t.cancel,
            style: TextStyle(color: AppColors.textOnGlassDim),
          ),
        ),
      ],
    ),
  );
  if (picked == null) return;

  final controller = ref.read(userChatFoldersControllerProvider.notifier);
  String folderId = picked;
  if (picked == createToken) {
    final name = await _askFolderName(context);
    if (name == null) return;
    final folder = await controller.create(name, chatIds: [chat.id]);
    folderId = folder.id;
  } else {
    await controller.addChat(picked, chat.id);
  }
  ref.read(selectedFolderProvider.notifier).state = null;
  ref.read(selectedUserFolderProvider.notifier).state = folderId;
}

Future<String?> _askFolderName(BuildContext context,
    {String initial = ''}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.bgTop,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      title: Text(
        _chatText(
          context,
          uk: '\u041d\u0430\u0437\u0432\u0430 \u043f\u0430\u043f\u043a\u0438',
          en: 'Folder name',
        ),
        style: TextStyle(color: AppColors.textOnGlass),
      ),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: TextStyle(color: AppColors.textOnGlass),
        decoration: InputDecoration(
          hintText: _chatText(context,
              uk: '\u0414\u0440\u0443\u0437\u0456', en: 'Friends'),
          hintStyle: TextStyle(color: AppColors.textOnGlassFaint),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(_chatText(context,
              uk: '\u0421\u043a\u0430\u0441\u0443\u0432\u0430\u0442\u0438',
              en: 'Cancel')),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
          child: Text(_chatText(context,
              uk: '\u0417\u0431\u0435\u0440\u0435\u0433\u0442\u0438',
              en: 'Save')),
        ),
      ],
    ),
  );
  controller.dispose();
  if (result == null || result.trim().isEmpty) return null;
  return result.trim();
}

Future<void> _markChatUnread(
  BuildContext context,
  WidgetRef ref,
  Chat chat, {
  bool showToast = true,
}) async {
  final messages = ref.read(messagesControllerProvider)[chat.id] ?? const [];
  final hasInbound = messages.any((m) => !m.isMine);
  if (!hasInbound) {
    if (showToast && context.mounted) {
      showGlassToast(
        context,
        _chatText(
          context,
          uk: '\u041d\u0435\u043c\u0430\u0454 \u0432\u0445\u0456\u0434\u043d\u0438\u0445 \u043f\u043e\u0432\u0456\u0434\u043e\u043c\u043b\u0435\u043d\u044c',
          en: 'No incoming messages',
        ),
        icon: Icons.mark_chat_unread_outlined,
        tone: ToastTone.neutral,
      );
    }
    return;
  }
  await ref.read(readMarkersControllerProvider.notifier).forget(chat.id);
  if (showToast && context.mounted) {
    showGlassToast(
      context,
      _chatText(
        context,
        uk: '\u041f\u043e\u0437\u043d\u0430\u0447\u0435\u043d\u043e \u044f\u043a \u043d\u0435\u043f\u0440\u043e\u0447\u0438\u0442\u0430\u043d\u0435',
        en: 'Marked as unread',
      ),
      icon: Icons.mark_chat_unread_outlined,
      tone: ToastTone.success,
    );
  }
}

Future<void> _confirmAndClearHistory(
  BuildContext context,
  WidgetRef ref,
  Chat chat,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.bgTop,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: AppColors.glass(0.15)),
      ),
      title: Text(
        _chatText(
          context,
          uk: '\u041e\u0447\u0438\u0441\u0442\u0438\u0442\u0438 \u0456\u0441\u0442\u043e\u0440\u0456\u044e \u0447\u0430\u0442\u0430?',
          en: 'Clear chat history?',
        ),
        style: TextStyle(
          color: AppColors.textOnGlass,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: Text(
        _chatText(
          context,
          uk: '\u041f\u043e\u0432\u0456\u0434\u043e\u043c\u043b\u0435\u043d\u043d\u044f \u0431\u0443\u0434\u0435 \u0432\u0438\u0434\u0430\u043b\u0435\u043d\u043e \u0442\u0456\u043b\u044c\u043a\u0438 \u043d\u0430 \u0446\u044c\u043e\u043c\u0443 \u043f\u0440\u0438\u0441\u0442\u0440\u043e\u0457. \u0427\u0430\u0442, \u043a\u043e\u043d\u0442\u0430\u043a\u0442 \u0456 \u043e\u0431\u0440\u0430\u043d\u0456 \u0437\u0430\u043b\u0438\u0448\u0430\u0442\u044c\u0441\u044f.',
          en: 'Messages will be removed only on this device. The chat, contact, and favorite state stay.',
        ),
        style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(
            AppLocalizations.of(ctx).cancel,
            style: TextStyle(color: AppColors.textOnGlassDim),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(
            _chatText(
              context,
              uk: '\u041e\u0447\u0438\u0441\u0442\u0438\u0442\u0438',
              en: 'Clear',
            ),
            style: const TextStyle(color: AppColors.danger),
          ),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  await ref.read(messagesControllerProvider.notifier).clearForChat(chat.id);
  await ref.read(readMarkersControllerProvider.notifier).forget(chat.id);
  await ref.read(pinnedControllerProvider.notifier).forget(chat.id);
  if (!context.mounted) return;
  showGlassToast(
    context,
    _chatText(
      context,
      uk: '\u0406\u0441\u0442\u043e\u0440\u0456\u044e \u043e\u0447\u0438\u0449\u0435\u043d\u043e',
      en: 'History cleared',
    ),
    icon: Icons.cleaning_services_outlined,
    tone: ToastTone.success,
  );
}

Future<void> _toggleBlocked(
  BuildContext context,
  WidgetRef ref,
  Chat chat, {
  required bool blocked,
  required AppLocalizations t,
}) async {
  if (chat.isChannel) return;
  await ref.read(knownPeersControllerProvider.notifier).setBlocked(
        chat.id,
        !blocked,
      );
  if (!context.mounted) return;
  showGlassToast(
    context,
    blocked ? t.peerUnblock : t.peerBlockedNote,
    icon: blocked ? Icons.lock_open_rounded : Icons.block_rounded,
    tone: blocked ? ToastTone.success : ToastTone.danger,
  );
}

Future<void> _confirmAndDeleteChat(
  BuildContext context,
  WidgetRef ref,
  Chat chat,
  AppLocalizations t,
) async {
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
    if (chat.isChannel) {
      // A room has many people in it and no member gets to erase it for the
      // rest, so this stays what it always was: retract what we wrote.
      for (final m in retractable) {
        await messaging.sendDeleteForEveryone(chat.id, m.wireId!);
      }
    } else {
      // One ask instead of one per message, and it takes the whole
      // conversation rather than only our half of it — which is what people
      // mean by deleting a chat for both, and what the per-message retraction
      // could never do.
      await messaging.sendConversationClear(chat.id);
    }
  }

  await ref.read(messagesControllerProvider.notifier).clearForChat(chat.id);
  await ref.read(favoritesControllerProvider.notifier).forget(chat.id);
  await ref.read(pinnedChatsControllerProvider.notifier).forget(chat.id);
  await ref
      .read(userChatFoldersControllerProvider.notifier)
      .forgetChat(chat.id);
  await ref.read(readMarkersControllerProvider.notifier).forget(chat.id);
  await ref.read(pinnedControllerProvider.notifier).forget(chat.id);
  await ref.read(draftsControllerProvider.notifier).clear(chat.id);
  if (chat.isChannel) {
    // Leaving forgets the key; without it the channel's broadcasts become
    // unreadable noise we simply relay.
    await ref.read(channelControllerProvider.notifier).leave(chat.id);
    await ref.read(channelRosterControllerProvider.notifier).forget(chat.id);
  } else {
    // The contact stays. Forgetting the roster entry is what used to make the
    // person disappear from Contacts along with their keys, their prekey and
    // their npub — so writing to them again meant swapping codes a second
    // time, for the crime of clearing a conversation. Hiding suppresses the
    // tile for exactly as long as the chat is empty; the next message either
    // way brings it back on its own.
    await ref.read(hiddenChatsControllerProvider.notifier).hide(chat.id);
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
