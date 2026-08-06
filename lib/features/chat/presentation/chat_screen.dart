import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../../core/notifications/notification_service.dart';
import 'package:file_picker/file_picker.dart';
import '../../../core/transport/file_reassembly.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/transport/chat_session.dart';
import '../../../core/transport/chat_session_manager.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/transport/nostr/websocket_relay_client.dart';
import '../../../core/util/app_lifecycle.dart';
import '../../../core/util/audio_trimmer.dart';
import '../../../core/util/debug_log.dart';
import '../../../core/util/media_storage.dart';
import '../../../core/utils/time_format.dart';
import '../../../core/utils/file_mime.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../peers/presentation/widgets/peer_avatar.dart';
import '../../../l10n/app_localizations.dart';
import '../../channels/data/channel_controller.dart';
import '../../channels/presentation/channel_poll_composer.dart';
import '../../chats/data/read_markers_controller.dart';
import '../../chats/data/saved_messages.dart';
import '../../../core/identity/anon_name.dart';
import '../../peers/data/contact_aliases_controller.dart';
import '../../peers/data/known_peers_controller.dart';
import '../../peers/data/peripheral_controller.dart';
import '../../peers/data/peer_discovery_controller.dart';
import '../../peers/data/presence_controller.dart';
import '../../peers/data/typing_controller.dart';
import '../../profile/data/privacy_settings_controller.dart';
import '../../profile/data/relay_settings_controller.dart';
import '../data/message_edit_target.dart';
import '../data/message_selection.dart';
import '../data/message_reply_target.dart';
import '../data/chat_navigation.dart';
import '../data/conversation_settings_controller.dart';
import '../data/drafts_controller.dart';
import '../data/messages_controller.dart';
import 'widgets/auto_delete_picker.dart';
import '../data/pinned_controller.dart';
import '../data/voice_recorder_controller.dart';
import '../models/message.dart';
import '../domain/command_processor.dart';
import '../../../core/util/image_encode.dart';
import 'camera_capture_screen.dart';
import 'media_preview_screen.dart';
import 'widgets/chat_input.dart';
import 'widgets/image_editor.dart';
import 'widgets/media_picker_sheet.dart';
import 'widgets/message_bubble.dart';
import 'widgets/voice_island.dart';
import 'widgets/voice_trim_bar.dart';
import 'widgets/chat_wallpaper_layer.dart';
import 'widgets/direct_mention_hint.dart';
import 'widgets/mention_suggestions.dart';
import '../../../core/routing/page_transitions.dart';
import '../../../core/widgets/glass_sheet.dart';
import '../../../core/widgets/glass_toast.dart';

/// True when [id] is a BLE device id (an Android MAC or an iOS UUID) rather
/// than the 64-char pubkey-hex the Chats list routes with. Only the former can
/// be handed to `BluetoothDevice.fromId` for a reconnect.
bool _isBleDeviceId(String id) =>
    !(id.length == 64 && RegExp(r'^[0-9a-f]+$').hasMatch(id));

final _chatSearchOpenProvider =
    StateProvider.autoDispose.family<bool, String>((_, __) => false);

enum ChatRoute { bluetooth, mesh, internet, queued }

ChatRoute resolveChatRoute({
  required bool directBluetooth,
  required bool meshAvailable,
  required bool relayAvailable,
}) {
  if (directBluetooth) return ChatRoute.bluetooth;
  if (meshAvailable) return ChatRoute.mesh;
  if (relayAvailable) return ChatRoute.internet;
  return ChatRoute.queued;
}

({ChatRoute route, int? hops}) displayedChatRoute(
  List<Message> messages,
  ChatRoute fallback,
) {
  for (var index = messages.length - 1; index >= 0; index--) {
    final message = messages[index];
    final stored = message.route;
    if (stored == null) continue;
    final route = switch (stored) {
      MessageRoute.bluetooth => ChatRoute.bluetooth,
      MessageRoute.mesh => ChatRoute.mesh,
      MessageRoute.internet => ChatRoute.internet,
      MessageRoute.queued => ChatRoute.queued,
    };
    return (route: route, hops: message.routeHops);
  }
  return (route: fallback, hops: null);
}

List<Message> messagesMatchingQuery(List<Message> messages, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return const <Message>[];
  return messages.where((message) {
    final searchable = <String>[
      message.text,
      if (message.fileName != null) message.fileName!,
      if (message.authorName != null) message.authorName!,
    ];
    return searchable.any((value) => value.toLowerCase().contains(needle));
  }).toList(growable: false);
}

bool _hasMeshLink(Map<String, ChatSession> sessions, int peripheralLinks) =>
    peripheralLinks > 0 ||
    sessions.values.any((session) => session.isEstablished);

bool _hasRelay(Map<String, RelayState> statuses) =>
    statuses.values.any((state) => state == RelayState.connected);

/// Real-transport chat screen.
///
/// Identifies the conversation by `peerId` (the transport-level BLE id), reads
/// messages from [messagesControllerProvider], and dispatches sends to
/// [messagingServiceProvider]. The handshake state is reflected in the AppBar
/// subtitle so the user can tell whether their messages will actually go out.
class ChatScreen extends ConsumerWidget {
  const ChatScreen({
    super.key,
    required this.peerId,
    required this.peerLabel,
    this.initialMessageId,
    this.returnToChats = false,
  });

  final String peerId;
  final String peerLabel;
  final String? initialMessageId;
  final bool returnToChats;

  void _goBack(BuildContext context) {
    if (returnToChats) {
      context.go('/chats');
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Widget _withBackHandling(BuildContext context, Widget child) {
    if (!returnToChats) return child;
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go('/chats');
      },
      child: child,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final messagesMap = ref.watch(messagesControllerProvider);

    // Group channel (`#name`): no Noise session, no presence — membership is
    // just holding the shared key. Send is enabled while we're a member.
    // Saved notes and channels are the same shape on screen: no presence, no
    // handshake, no route indicator — just a conversation. Saved goes through
    // the channel build for that reason, and the composer tells them apart.
    if (peerId.startsWith('#') || isSavedChat(peerId)) {
      return _buildChannel(context, ref, t);
    }

    final sessions = ref.watch(chatSessionManagerProvider);

    // `peerId` from the URL can be either a BLE transport id (when we got
    // here from a Nearby tap) or a pubkey-hex chat id (when re-entered from
    // the main Chats list). Resolve to a live session by either route.
    ChatSession? session = sessions[peerId];
    if (session == null) {
      for (final s in sessions.values) {
        if (s.remotePubkeyHex == peerId) {
          session = s;
          break;
        }
      }
    }

    // Prefer the canonical pubkey-keyed bucket; fall back to the transport
    // id (for chats that are still on the BLE-address URL).
    final canonicalId = session?.remotePubkeyHex ?? peerId;
    final messages =
        messagesMap[canonicalId] ?? messagesMap[peerId] ?? const [];
    // A prior announcement gives us the peer's pubkey (and, when present, their
    // Nostr npub) even with no live BLE session — enough for sendText to carry
    // a frame over the mesh, the Nostr internet fallback, or store-and-forward.
    final known = ref.watch(knownPeersControllerProvider)[canonicalId];
    final availableRoute = resolveChatRoute(
      directBluetooth: session?.isEstablished ?? false,
      meshAvailable: _hasMeshLink(
        sessions,
        ref.watch(peripheralControllerProvider).connectedCount,
      ),
      relayAvailable: known?.nostrPubkey != null &&
          _hasRelay(ref.watch(relayStatusProvider)),
    );
    final route = displayedChatRoute(messages, availableRoute);
    // Sending needs a recipient pubkey, not a live handshake. Gating on
    // isEstablished made Send a silent no-op whenever the peer wasn't a direct
    // BLE neighbour: two phones talking only over the internet could type but
    // nothing ever left the phone (no bubble, no error). Enable Send whenever we
    // can address the peer at all — sendText appends the bubble and it shows a
    // clock until a transport (mesh / Nostr / store-and-forward) takes it.
    final canSend = (session?.isEstablished ?? false) || known != null;

    // The header name is resolved here rather than taken from [peerLabel],
    // which is a route query parameter and therefore frozen at the moment the
    // chat was opened. Renaming somebody from their profile and coming back to
    // a header still showing the old name is the obvious way for this to feel
    // broken, and watching the alias store is what stops it.
    final aliases = ref.watch(contactAliasesControllerProvider);
    final headerLabel = known == null
        ? peerLabel
        : contactDisplayName(
            alias: aliases[known.pubkeyHex],
            rawBroadcastName: known.displayName,
            pubkeyHex: known.pubkeyHex,
          );

    // Offer a reconnect whenever there's no live session to speak over — the
    // old condition only covered a session that reached `failed`, but a GATT
    // connect that times out never creates one, leaving the screen stuck on
    // "waiting for the handshake" with no way out. Only meaningful when we
    // routed here with a device id: a chat opened from the Chats list carries
    // a pubkey-hex, and you cannot open a GATT link to a public key.
    final showRetry = _isBleDeviceId(peerId) &&
        (session == null || session.status == ChatSessionStatus.failed);

    // Presence: a live session, else a fresh beacon (the internet case), else
    // how recently they were announcing on the mesh. See [peerIsOnline].
    // Drives the timer beside the name in the header.
    final autoDelete = ref
            .watch(conversationSettingsControllerProvider)[canonicalId]
            ?.autoDelete ??
        ChatAutoDelete.off;
    final lastSeen = known?.lastSeen;
    final presenceShared = ref.watch(privacySettingsProvider).shareLastSeen;
    final isOnline = peerIsOnline(
      hasLiveSession: session?.isEstablished ?? false,
      beacon: ref.watch(presenceControllerProvider)[canonicalId],
      lastSeen: lastSeen,
      presenceShared: presenceShared,
    );
    // Watched, not read, so the line updates when a notice lands. The TTL is
    // what makes it go away again — see [TypingController].
    ref.watch(typingControllerProvider);
    final isTyping =
        ref.read(typingControllerProvider.notifier).isTyping(canonicalId);

    final String statusText;
    if (session != null &&
        (session.status == ChatSessionStatus.handshakingInitiator ||
            session.status == ChatSessionStatus.handshakingResponder ||
            session.status == ChatSessionStatus.idle)) {
      statusText = t.chatSessionHandshaking;
    } else if (session != null && session.status == ChatSessionStatus.failed) {
      statusText = t.chatSessionFailed;
    } else if (isTyping) {
      // Ahead of "online": somebody typing is online by definition, and the
      // more specific fact is the one worth the one line there is.
      statusText = t.chatTyping;
    } else if (isOnline) {
      statusText = t.presenceOnline;
    } else if (!presenceShared) {
      // Say why the line is empty of presence rather than showing a stale time
      // that reads as fact. A live session is still reported above, because
      // that is something we know without anybody telling us.
      statusText = t.presenceHidden;
    } else if (lastSeen != null) {
      // "offline · 14:05" / "offline · Mon" — precise last-seen.
      statusText =
          '${t.presenceOffline} · ${formatChatListTime(context, lastSeen)}';
    } else {
      statusText = t.presenceOffline;
    }

    final pubkeyHex = session?.remotePubkeyHex ?? known?.pubkeyHex;

    return _withBackHandling(
        context,
        Scaffold(
          backgroundColor: Colors.transparent,
          // No AppBar: the header is an island floating over the conversation (see
          // _FloatingComposerBody), not a bar that owns a band of the screen.
          body: _ConversationView(
            chatId: canonicalId,
            messages: messages,
            initialMessageId: initialMessageId,
            canSend: canSend,
            composer: _ChatBottomBar(
              peerId: peerId,
              canonicalId: canonicalId,
              canSend: canSend,
            ),
            header: _ChatHeader(
              onBack: () => _goBack(context),
              chatId: canonicalId,
              avatarSeed: peerId,
              label: headerLabel,
              autoDeleteLabel:
                  autoDelete.isOn ? formatAutoDelete(t, autoDelete) : null,
              statusText: statusText,
              verification: _VerificationMark(session: session, ref: ref),
              route: route.route,
              routeHops: route.hops,
              statusColor:
                  isOnline ? AppColors.online : AppColors.textOnGlassDim,
              online: isOnline,
              // Tapping the identity pill goes where the shield goes — the peer's
              // fingerprint screen is the only "profile" this app has.
              onTapIdentity: pubkeyHex == null
                  ? null
                  : () => context.push(
                        '/person/${Uri.encodeComponent(pubkeyHex)}'
                        '?name=${Uri.encodeQueryComponent(headerLabel)}',
                      ),
              actions: [
                _PillIconButton(
                  icon: Icons.search_rounded,
                  color: AppColors.textOnGlass,
                  tooltip: t.chatSearchTitle,
                  onPressed: () => ref
                      .read(_chatSearchOpenProvider(canonicalId).notifier)
                      .state = true,
                ),
                if (showRetry)
                  _PillIconButton(
                    icon: Icons.refresh,
                    color: AppColors.brandPrimary,
                    tooltip: t.bleRetry,
                    onPressed: () async {
                      final manager =
                          ref.read(chatSessionManagerProvider.notifier);
                      manager.drop(peerId);
                      final scanner = ref.read(bleScannerProvider);
                      try {
                        await ref
                            .read(messagingServiceProvider)
                            .connectAsInitiatorWithRetry(
                              deviceId: peerId,
                              displayName: peerLabel,
                              refreshId: () => scanner.refreshPeerId(peerLabel),
                            );
                      } catch (_) {
                        if (!context.mounted) return;
                        showGlassToast(context, t.bleConnectFailed,
                            tone: ToastTone.danger);
                      }
                    },
                  ),
                // No shield here. Verification is a property of the person,
                // not of this conversation, and the contact profile already
                // carries a Security card that opens the same screen. What the
                // header needs to say is only *whether* they are verified,
                // which is now a mark beside the name.
              ],
            ),
          ),
        ));
  }

  /// Dedicated build for a group channel — a flat, presence-free variant of
  /// the peer chat. The conversation is keyed by the channel name and every
  /// send fans out as a broadcast to all members.
  Widget _buildChannel(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations t,
  ) {
    // A saved-notes chat is never "joined" — there is nothing to join — but it
    // is always writable, which is the only thing `joined` gates.
    final saved = isSavedChat(peerId);
    final joined =
        saved || ref.watch(channelControllerProvider).containsKey(peerId);
    final messages = ref.watch(messagesControllerProvider)[peerId] ?? const [];

    final sessions = ref.watch(chatSessionManagerProvider);
    final availableRoute = resolveChatRoute(
      directBluetooth: false,
      meshAvailable: _hasMeshLink(
        sessions,
        ref.watch(peripheralControllerProvider).connectedCount,
      ),
      relayAvailable: _hasRelay(ref.watch(relayStatusProvider)),
    );
    final route = displayedChatRoute(messages, availableRoute);
    return _withBackHandling(
        context,
        Scaffold(
          backgroundColor: Colors.transparent,
          body: _ConversationView(
            chatId: peerId,
            messages: messages,
            initialMessageId: initialMessageId,
            canSend: joined,
            composer: _ChatBottomBar(
              peerId: peerId,
              canonicalId: peerId,
              canSend: joined,
              // Saved notes are not a broadcast; the composer branches on the
              // reserved id before it consults this.
              isChannel: !saved,
            ),
            header: _ChatHeader(
              onBack: () => _goBack(context),
              chatId: peerId,
              avatarSeed: peerId,
              label: peerLabel,
              statusText: saved ? t.savedSubtitle : t.channelSubtitle,
              statusColor: AppColors.textOnGlassDim,
              route: saved ? null : route.route,
              routeHops: saved ? null : route.hops,
              online: false,
              // Notes to yourself have no other end to look at, so the tap
              // opens what a notebook does have: everything in it, sorted —
              // media, voice, files, links. (It used to open channel info for
              // a channel called `saved`, which not only showed a room that
              // does not exist but *created* one on the way in: ensureSelf
              // writes a roster entry for whatever name it is handed.)
              onTapIdentity: saved
                  ? () => context.push('/saved/content')
                  : () => context.push(
                        '/channel-info/${Uri.encodeComponent(peerId.substring(1))}',
                      ),
              // Search, and nothing else.
              //
              // The header used to carry three: search, start a poll, add
              // people. Two of them have somewhere better to be now — a poll is
              // one of the things you attach, so it sits in the attach sheet
              // beside the gallery and the camera, and adding people is what
              // the channel profile is for, which is one tap away on the title.
              // Three icons deep, the room's own name had nowhere to go but
              // ellipsis.
              actions: [
                if (joined)
                  _PillIconButton(
                    icon: Icons.search_rounded,
                    color: AppColors.textOnGlass,
                    tooltip: t.chatSearchTitle,
                    onPressed: () => ref
                        .read(_chatSearchOpenProvider(peerId).notifier)
                        .state = true,
                  ),
              ],
            ),
          ),
        ));
  }
}

/// Height of the single header capsule. Its six-pixel inner padding leaves
/// enough room for the 44-pixel circular edge buttons used by the composer.
const double _headerPillHeight = 56;

/// The one floating glass capsule that owns the whole chat header.
/// Its contents mirror the message composer: circular controls at the edges
/// and flexible content in the middle.
class _HeaderPill extends StatelessWidget {
  const _HeaderPill({
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 8),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _headerPillHeight,
      child: MessageIslandGlass(
        key: const ValueKey('chat-header-message-island'),
        borderRadius: _headerPillHeight / 2,
        padding: padding,
        child: Center(child: child),
      ),
    );
  }
}

/// Icon button sized to sit inside a [_HeaderPill] without the 48-px slop
/// IconButton reserves by default (which would fight the pill's own padding).
class _PillIconButton extends StatelessWidget {
  const _PillIconButton({
    required this.icon,
    required this.onPressed,
    required this.color,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final Color color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, color: color, size: 21),
      onPressed: onPressed,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 38, height: 38),
      splashRadius: 22,
    );
  }
}

/// A circular control embedded in the shared header capsule, matching the
/// attachment and microphone controls inside the message composer.
class _HeaderActionCircle extends StatelessWidget {
  const _HeaderActionCircle({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.glass(0.18),
            AppColors.glass(0.10),
          ],
        ),
      ),
      child: Center(child: child),
    );
  }
}

/// Telegram-style chat header: one long glass capsule with circular controls
/// embedded at its edges, just like the message composer.
class _ChatHeader extends StatelessWidget {
  const _ChatHeader({
    required this.onBack,
    required this.chatId,
    required this.avatarSeed,
    required this.label,
    required this.statusText,
    this.verification,
    required this.route,
    this.autoDeleteLabel,
    this.routeHops,
    required this.statusColor,
    required this.online,
    required this.actions,
    this.onTapIdentity,
  });

  final VoidCallback onBack;

  /// Which conversation this header belongs to — the voice island claims it
  /// so the app-wide bar stands down while we are here.
  final String chatId;
  final String avatarSeed;
  final String label;

  /// Message lifetime for this conversation when one is set, so the header can
  /// carry a timer next to the name. Null when messages are kept.
  final String? autoDeleteLabel;
  final String statusText;
  /// Small mark beside the name — verified, or key-changed. Null for a
  /// channel, which has no single person to vouch for.
  final Widget? verification;
  /// How a message would leave here. Null when none would: notes to yourself
  /// are written straight to disk, and a globe over a notebook claims the
  /// opposite of what is true.
  final ChatRoute? route;
  final int? routeHops;
  final Color statusColor;
  final bool online;
  final List<Widget> actions;
  final VoidCallback? onTapIdentity;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Own the status-bar inset here: without an AppBar there is nothing else
      // holding the capsule clear of the notch, and the conversation behind it
      // deliberately runs all the way to the top of the screen.
      padding:
          EdgeInsets.fromLTRB(8, MediaQuery.paddingOf(context).top + 4, 8, 4),
      // Always the header. A playing voice note used to take this capsule over
      // and put the header on the back of it, reachable by a downward swipe —
      // which meant that while anything was playing there was no back button on
      // screen and no sign that there had ever been one. It has its own island
      // under this one now; see [ChatVoiceBar].
      child: _HeaderPill(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          children: [
            _HeaderActionCircle(
              child: _PillIconButton(
                icon: Icons.arrow_back_rounded,
                color: AppColors.textOnGlass,
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: onBack,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onTapIdentity,
                  borderRadius: BorderRadius.circular(20),
                  child: Row(
                    children: [
                      PeerAvatar(
                        peerId: avatarSeed,
                        label: label,
                        size: 36,
                        online: online,
                        heroTag: 'avatar-$avatarSeed',
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          // Centred against the avatar. The two lines have
                          // different natural heights, so left to itself the
                          // block sat high and the name looked off its own
                          // picture.
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Row(
                              // Baseline-ish: the marks beside the name are
                              // smaller than the name, and centring them on the
                              // row made them float above its middle.
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Flexible(
                                  child: Text(
                                    label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTypography.heading(
                                      size: 15.5,
                                      color: AppColors.textOnGlass,
                                    ),
                                  ),
                                ),
                                // A timer beside the name, the way every
                                // messenger marks a disappearing conversation.
                                // The exact period is one tap away in the
                                // profile; here the point is only that this
                                // chat does not keep what you say in it.
                                // Verified — or key-changed — reads as a mark on
                                // the name, which is whose property it is. It
                                // replaces the shield that used to sit out at
                                // the end of the row, where it looked like
                                // another button rather than a statement about
                                // this person.
                                if (verification != null) ...[
                                  const SizedBox(width: 5),
                                  verification!,
                                ],
                                if (autoDeleteLabel != null) ...[
                                  const SizedBox(width: 6),
                                  Tooltip(
                                    message: autoDeleteLabel!,
                                    child: Icon(
                                      Icons.timer_outlined,
                                      size: 14,
                                      color: AppColors.brandPrimary,
                                    ),
                                  ),
                                ],
                                // The message count is gone. It answered a
                                // question nobody asks mid-conversation and sat
                                // where a name wants to be.
                              ],
                            ),
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final compactRoute = constraints.maxWidth < 140;
                                return Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        statusText,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: statusColor,
                                          fontSize: 11.5,
                                        ),
                                      ),
                                    ),
                                    if (route != null) ...[
                                      SizedBox(width: compactRoute ? 4 : 6),
                                      _ChatRouteIndicator(
                                        route: route!,
                                        hops: routeHops,
                                        compact: compactRoute,
                                      ),
                                    ],
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(width: 6),
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                _HeaderActionCircle(child: actions[i]),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _ChatRouteIndicator extends StatelessWidget {
  const _ChatRouteIndicator({
    required this.route,
    this.hops,
    this.compact = false,
  });

  final ChatRoute route;
  final int? hops;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final (icon, baseLabel, color) = switch (route) {
      ChatRoute.bluetooth => (
          Icons.bluetooth_rounded,
          t.chatRouteBluetooth,
          AppColors.brandPrimary,
        ),
      ChatRoute.mesh => (
          Icons.hub_outlined,
          t.chatRouteMesh,
          AppColors.brandSecondary,
        ),
      ChatRoute.internet => (
          Icons.public_rounded,
          t.chatRouteInternet,
          AppColors.online,
        ),
      ChatRoute.queued => (
          Icons.schedule_send_outlined,
          t.chatRouteQueued,
          AppColors.warning,
        ),
    };
    final label = route == ChatRoute.mesh && hops != null
        ? '$baseLabel · $hops'
        : baseLabel;
    return Tooltip(
      message: label,
      child: compact
          ? Icon(icon, size: 13, color: color)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 12, color: color),
                const SizedBox(width: 3),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
    );
  }
}

/// The conversation itself: an optional pinned-message bar, the message list,
/// and the floating composer.
///
/// It owns the list's [ScrollController] because the pinned bar has to be able
/// to scroll the conversation to the message it names — the two can't be
/// assembled independently.
class _ConversationView extends ConsumerStatefulWidget {
  const _ConversationView({
    required this.chatId,
    required this.messages,
    this.initialMessageId,
    required this.canSend,
    required this.composer,
    required this.header,
  });

  /// The floating header capsule. Passed in rather than built here because the
  /// peer and channel variants fill it differently.
  final Widget header;

  /// Bucket key for this conversation: a peer's pubkey-hex or a `#channel`.
  final String chatId;
  final List<Message> messages;
  final String? initialMessageId;
  final bool canSend;
  final Widget composer;

  @override
  ConsumerState<_ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends ConsumerState<_ConversationView> {
  final _scroll = ScrollController();

  /// Attached to the pinned message's bubble (and only to that one) so a jump
  /// can finish with [Scrollable.ensureVisible] once it is actually built.
  final _initialMessageKey = GlobalKey();
  final _searchResultKey = GlobalKey();

  /// Rides on whichever message is currently flashing, so a jump can finish on
  /// the message it was asked for. It used to finish on the *pinned* message
  /// whatever the destination was — fine while the only jump was the pinned
  /// bar, wrong as soon as a tapped quote pointed somewhere else, which landed
  /// you near the message instead of on it.
  final _jumpTargetKey = GlobalKey();
  String _searchQuery = '';
  int _searchIndex = 0;

  /// How many times the pinned bar has been tapped. The bar itself shows where
  /// the *next* tap goes, counting up from the newest pin, so this is a step
  /// count rather than an index into anything.
  int _pinStep = 0;
  bool _initialMessageRevealed = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScrollChanged);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _revealInitialMessage());
  }

  @override
  void didUpdateWidget(covariant _ConversationView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_initialMessageRevealed) return;
    if (oldWidget.initialMessageId != widget.initialMessageId ||
        oldWidget.messages.length != widget.messages.length) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _revealInitialMessage());
    }
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _scroll.removeListener(_onScrollChanged);
    _scroll.dispose();
    super.dispose();
  }

  /// True once the newest message is comfortably off screen. The threshold is
  /// about a screenful: a button that appears the instant you nudge the list
  /// flickers in and out while reading.
  bool _canScrollDown = false;

  void _onScrollChanged() {
    if (!_scroll.hasClients) return;
    // reverse: true, so offset 0 *is* the bottom.
    final next = _scroll.offset > 600;
    if (next != _canScrollDown) setState(() => _canScrollDown = next);
  }

  /// Scroll the conversation to the message the chat was opened at.
  ///
  /// Bubble heights vary (one-liners, photos, quoted replies), so there is no
  /// offset to compute directly — [_jumpToMessageId] converges on it instead.
  /// Only marked done once it actually landed, so a jump that ran out of
  /// history is retried when more of it arrives.
  Future<void> _revealInitialMessage() async {
    final messageId = widget.initialMessageId;
    if (messageId == null || _initialMessageRevealed || !mounted) return;
    if (await _jumpToMessageId(messageId, _initialMessageKey)) {
      _initialMessageRevealed = true;
    }
  }

  /// Flash the message we just landed on, then let it fade.
  ///
  /// Arriving somewhere in the middle of a scrollback with nothing marking the
  /// destination is why jumping felt like the screen had simply moved.
  Timer? _highlightTimer;

  void _flash(String messageId) {
    ref.read(chatHighlightProvider(widget.chatId).notifier).state = messageId;
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 1600), () {
      if (!mounted) return;
      final marker = ref.read(chatHighlightProvider(widget.chatId).notifier);
      if (marker.state == messageId) marker.state = null;
    });
  }

  Future<void> _jumpTo(String wireId) async {
    final messages = widget.messages;
    final index = messages.indexWhere((m) => m.wireId == wireId);
    if (index < 0) {
      final t = AppLocalizations.of(context);
      showGlassToast(context, t.chatPinnedGone);
      return;
    }
    // Flash first: the marker is also what puts [_jumpTargetKey] on the
    // destination, so the scroll below has something to finish against.
    _flash(messages[index].id);
    await _jumpToMessageId(messages[index].id, _jumpTargetKey);
  }

  void _updateSearch(String query) {
    final matches = messagesMatchingQuery(widget.messages, query);
    setState(() {
      _searchQuery = query;
      _searchIndex = matches.isEmpty ? 0 : matches.length - 1;
    });
    if (matches.isNotEmpty) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _revealSearchResult());
    }
  }

  void _moveSearch(int delta) {
    final matches = messagesMatchingQuery(widget.messages, _searchQuery);
    if (matches.isEmpty) return;
    setState(() {
      _searchIndex = (_searchIndex + delta) % matches.length;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealSearchResult());
  }

  void _closeSearch() {
    ref.read(_chatSearchOpenProvider(widget.chatId).notifier).state = false;
    setState(() {
      _searchQuery = '';
      _searchIndex = 0;
    });
  }

  Future<void> _revealSearchResult() async {
    final matches = messagesMatchingQuery(widget.messages, _searchQuery);
    if (matches.isEmpty || !mounted) return;
    final index =
        _searchIndex >= matches.length ? matches.length - 1 : _searchIndex;
    await _jumpToMessageId(matches[index].id, _searchResultKey);
  }

  /// Scroll until [messageId]'s bubble exists, then land on it precisely.
  ///
  /// A `ListView.builder` only builds what is near the viewport, so the target
  /// usually has no context to `ensureVisible` against yet — and its own
  /// `maxScrollExtent` is a *guess* extrapolated from the items laid out so
  /// far. One jump against that guess and a handful of polls was enough on a
  /// short history and hopeless on a long one: the estimate landed nowhere near
  /// the message, the target never built, and the jump simply gave up wherever
  /// it had dropped you.
  ///
  /// So re-estimate every frame instead. Each jump lays out a new stretch of
  /// the list, which sharpens the extent, which sharpens the next estimate —
  /// it converges in a few frames however far back the message is.
  /// True once the message was actually brought on screen, so callers that only
  /// get one chance — the open-at-message jump — can tell a landing from a
  /// give-up and retry when more history arrives.
  Future<bool> _jumpToMessageId(String messageId, GlobalKey targetKey) async {
    final messages = widget.messages;
    final index = messages.indexWhere((message) => message.id == messageId);
    if (index < 0 || messages.isEmpty) return false;
    // reverse: true, so distance from the newest message is the scroll axis.
    final fromNewest = messages.length - 1 - index;

    for (var attempt = 0; attempt < 16; attempt++) {
      if (!mounted) return false;
      final targetContext = targetKey.currentContext;
      if (targetContext != null && targetContext.mounted) {
        await Scrollable.ensureVisible(
          targetContext,
          alignment: 0.35,
          duration: const Duration(milliseconds: 220),
        );
        return true;
      }
      if (_scroll.hasClients && messages.length > 1) {
        final position = _scroll.position;
        final estimate =
            position.maxScrollExtent * (fromNewest / (messages.length - 1));
        final next = estimate.clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        // Already sitting where the estimate says and still nothing built: the
        // extent has stopped improving, so more jumps will not help.
        if (attempt > 0 && (next - position.pixels).abs() < 1) return false;
        _scroll.jumpTo(next);
      }
      await WidgetsBinding.instance.endOfFrame;
    }
    return false;
  }

  /// Forward everything ticked into one other chat.
  ///
  /// Chronological rather than tap order: a forwarded conversation that
  /// arrives shuffled reads as a different conversation.
  Future<void> _forwardSelection(Set<String> ids) async {
    final t = AppLocalizations.of(context);
    final restricted = ref
            .read(conversationSettingsControllerProvider)[widget.chatId]
            ?.copyingRestricted ??
        false;
    final picked = [
      for (final m in widget.messages)
        if (ids.contains(m.id) &&
            messageCanBeForwarded(m, copyingRestricted: restricted))
          m,
    ];
    if (picked.isEmpty) {
      // Everything ticked was a photo, a voice note, or a view-once — say so
      // rather than opening a picker that could only disappoint.
      showGlassToast(context, t.chatForwardNothing, tone: ToastTone.danger);
      return;
    }
    final target = await pickForwardTarget(context, ref, widget.chatId);
    if (target == null || !mounted) return;
    for (final m in picked) {
      await forwardTextTo(ref, target, m.text);
    }
    if (!mounted) return;
    ref.read(messageSelectionProvider(widget.chatId).notifier).clear();
    showGlassToast(
      context,
      t.chatForwardSent(target.peerName),
      icon: Icons.shortcut_outlined,
      tone: ToastTone.success,
    );
  }

  /// Delete everything ticked.
  ///
  /// "For everyone" is offered only when *every* ticked message qualifies —
  /// a mixed selection where the button silently applies to some of them is
  /// worse than not offering it.
  Future<void> _deleteSelection(Set<String> ids) async {
    final t = AppLocalizations.of(context);
    final picked = [
      for (final m in widget.messages)
        if (ids.contains(m.id)) m,
    ];
    if (picked.isEmpty) return;
    final canForEveryone =
        picked.every((m) => m.isMine && m.wireId != null);

    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: AppColors.bgTop,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: AppColors.glass(0.15)),
        ),
        title: Text(
          t.chatDeleteSelectedTitle(picked.length),
          style: TextStyle(
            color: AppColors.textOnGlass,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        children: [
          if (canForEveryone)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop('everyone'),
              child: Text(
                t.chatDeleteForEveryone,
                style: TextStyle(color: AppColors.danger),
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('me'),
            child: Text(
              t.chatDeleteForMe,
              style: TextStyle(color: AppColors.textOnGlass),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(),
            child:
                Text(t.cancel, style: TextStyle(color: AppColors.textOnGlassDim)),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;

    if (choice == 'everyone') {
      final messaging = ref.read(messagingServiceProvider);
      for (final m in picked) {
        await messaging.sendDeleteForEveryone(widget.chatId, m.wireId!);
      }
    } else {
      ref
          .read(messagesControllerProvider.notifier)
          .deleteManyLocal(widget.chatId, ids);
    }
    if (!mounted) return;
    ref.read(messageSelectionProvider(widget.chatId).notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.messages;
    ref.watch(pinnedControllerProvider);
    // Pinning or unpinning anything puts the bar back on the newest pin.
    // Leaving the cursor where it was after the set changed under it meant the
    // bar could come back pointing at an arbitrary one.
    ref.listen<Map<String, PinnedMessage>>(pinnedControllerProvider, (_, __) {
      if (_pinStep != 0) setState(() => _pinStep = 0);
    });
    final pins =
        ref.read(pinnedControllerProvider.notifier).pinnedAllIn(widget.chatId);
    // Ordered by where each pin sits in the conversation, not by when it was
    // pinned: the bar walks *upward* through the history, so "the next one" has
    // to mean the one above it, whatever order they were pinned in.
    //
    // A pin whose message isn't in this chat any more (deleted, or history
    // cleared) has nothing to show or scroll to, so it drops out here rather
    // than rendering an empty row.
    final pinnedIds = {for (final pin in pins) pin.wireId};
    final visiblePins = [
      for (final m in messages)
        if (m.wireId != null && pinnedIds.contains(m.wireId)) m,
    ];
    // Start at the newest pin — the one nearest what you are reading — and
    // climb one pin per tap.
    final pinIndex = visiblePins.isEmpty
        ? 0
        : visiblePins.length - 1 - (_pinStep % visiblePins.length);
    final pinnedMessage = visiblePins.isEmpty ? null : visiblePins[pinIndex];
    // Anything in the tree can ask to be taken to a message — a tapped quote,
    // most of all. Answered here because this is where the scroll controller
    // lives, and cleared immediately so the same request cannot re-fire.
    ref.listen<String?>(chatJumpRequestProvider(widget.chatId), (_, wireId) {
      if (wireId == null) return;
      ref.read(chatJumpRequestProvider(widget.chatId).notifier).state = null;
      unawaited(_jumpTo(wireId));
    });

    final flashing = ref.watch(chatHighlightProvider(widget.chatId));
    final searchOpen = ref.watch(_chatSearchOpenProvider(widget.chatId));
    final selection = ref.watch(messageSelectionProvider(widget.chatId));
    final selecting = selection.isNotEmpty;
    final matches = messagesMatchingQuery(messages, _searchQuery);
    final selectedIndex = matches.isEmpty
        ? 0
        : (_searchIndex >= matches.length ? matches.length - 1 : _searchIndex);
    final selectedMessage = matches.isEmpty ? null : matches[selectedIndex];

    // Behind the conversation and in front of the route's aurora. Draws
    // nothing at all unless this chat has been given a wallpaper, so every
    // other chat is untouched.
    return ChatWallpaperLayer(
      chatId: widget.chatId,
      child: _FloatingComposerBody(
      scrollToBottom: _canScrollDown
          ? () => _scroll.animateTo(
                0,
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutCubic,
              )
          : null,
      listBuilder: (padding) => messages.isEmpty
          ? _EmptyConversationState(canSend: widget.canSend)
          : ListView.builder(
              reverse: true,
              controller: _scroll,
              padding: padding,
              itemCount: messages.length,
              itemBuilder: (_, i) {
                final m = messages[messages.length - 1 - i];
                Widget bubble =
                    MessageBubble(message: m, chatId: widget.chatId);
                if (m.id == widget.initialMessageId) {
                  bubble = KeyedSubtree(key: _initialMessageKey, child: bubble);
                }
                if (m.id == flashing) {
                  bubble = KeyedSubtree(key: _jumpTargetKey, child: bubble);
                }
                if (selectedMessage?.id == m.id) {
                  bubble = KeyedSubtree(
                    key: _searchResultKey,
                    child: _SearchResultHighlight(child: bubble),
                  );
                }
                return bubble;
              },
            ),
      composer: widget.composer,
      // Header and pinned island are siblings of the list inside the Stack, so
      // appearing or vanishing no longer re-parents the list — which used to
      // detach the scroll position and snap the conversation to the bottom
      // whenever someone pinned a message while reading back through history.
      header: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Selecting replaces the header for the same reason searching does:
          // one row at the top, and while you are ticking messages the count
          // and the two actions are the only things that matter.
          if (selecting)
            _ChatSelectionBar(
              count: selection.length,
              onCancel: () => ref
                  .read(messageSelectionProvider(widget.chatId).notifier)
                  .clear(),
              onForward: () => unawaited(_forwardSelection(selection)),
              onDelete: () => unawaited(_deleteSelection(selection)),
            ),
          // Searching *replaces* the identity row rather than stacking under
          // it. Two pills deep, the conversation started below the middle of
          // the screen and the thing you were reading was the thing pushed off
          // it — and while you are typing a query, whose chat it is is the one
          // thing you already know.
          if (!searchOpen && !selecting) widget.header,
          if (searchOpen && !selecting)
            _ChatSearchBar(
              totalMessages: messages.length,
              resultIndex: matches.isEmpty ? null : selectedIndex + 1,
              resultCount: matches.length,
              onChanged: _updateSearch,
              onPrevious: () => _moveSearch(-1),
              onNext: () => _moveSearch(1),
              onClose: _closeSearch,
            ),
          // Grown and shrunk, not swapped. Pinning a message moved the whole
          // conversation down a notch in a single frame, and unpinning yanked
          // it back — the list's top padding is measured off this column, so
          // easing the box eases the conversation with it.
          _HeaderSlot(
            child: pinnedMessage == null
                ? null
                : _PinnedBar(
                    message: pinnedMessage,
                    index: pinIndex,
                    count: visiblePins.length,
                    // One tap does both jobs, the way Telegram's bar does:
                    // take me to this pin, and leave the bar pointing at the
                    // one above it. A separate "next" chevron meant reading
                    // four pins took eight taps, alternating between two
                    // buttons a few pixels apart.
                    onTap: () {
                      if (visiblePins.length > 1) {
                        setState(
                          () => _pinStep = (_pinStep + 1) % visiblePins.length,
                        );
                      }
                      unawaited(_jumpTo(pinnedMessage.wireId!));
                    },
                    // Unpinning clears the banner for everyone in the chat, not
                    // just here, and the button sits next to one you tap to
                    // jump — easy to hit by accident, impossible to undo
                    // without finding the message again.
                    onUnpin: () async {
                      final t = AppLocalizations.of(context);
                      if (!await confirmAction(
                        context,
                        title: t.chatUnpinConfirm,
                        message: t.chatUnpinConfirmHint,
                        confirmLabel: t.chatUnpinAction,
                        destructive: false,
                      )) {
                        return;
                      }
                      await ref.read(messagingServiceProvider).sendPin(
                            widget.chatId,
                            pinnedMessage.wireId!,
                            pinned: false,
                          );
                    },
                  ),
          ),
          // Last in the stack, and only while something is playing: whose chat
          // this is comes first, then what is pinned in it, then what is coming
          // out of the speaker. The list pads itself to whatever this column
          // measures, so appearing and vanishing costs the conversation nothing
          // but a reflow.
          ChatVoiceBar(chatId: widget.chatId),
        ],
      ),
      ),
    );
  }
}

class _SearchResultHighlight extends StatelessWidget {
  const _SearchResultHighlight({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.brandPrimary.withValues(alpha: 0.08),
        border: Border(
          left: BorderSide(
            color: AppColors.brandPrimary.withValues(alpha: 0.85),
            width: 3,
          ),
        ),
      ),
      child: child,
    );
  }
}

/// One row of the header stack that may or may not be there.
///
/// The conversation's top padding is measured off the whole column, so a bar
/// that simply appeared moved every message down a notch in one frame, and
/// removing it snapped them back. Growing the box eases the list with it, and
/// the fade keeps content from arriving at full strength before there is room
/// for it.
class _HeaderSlot extends StatelessWidget {
  const _HeaderSlot({required this.child});

  /// Null when the row is not there.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: AnimatedOpacity(
          opacity: child == null ? 0 : 1,
          duration: const Duration(milliseconds: 160),
          child: child ?? const SizedBox(width: double.infinity),
        ),
      ),
    );
  }
}

class _ChatSearchBar extends StatefulWidget {
  const _ChatSearchBar({
    required this.totalMessages,
    required this.resultIndex,
    required this.resultCount,
    required this.onChanged,
    required this.onPrevious,
    required this.onNext,
    required this.onClose,
  });

  final int totalMessages;
  final int? resultIndex;
  final int resultCount;
  final ValueChanged<String> onChanged;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onClose;

  @override
  State<_ChatSearchBar> createState() => _ChatSearchBarState();
}

class _ChatSearchBarState extends State<_ChatSearchBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final counter = widget.resultIndex != null
        ? widget.resultIndex.toString() + ' / ' + widget.resultCount.toString()
        : _query.trim().isEmpty
            ? widget.totalMessages.toString()
            : t.chatSearchNoResults;
    final canNavigate = widget.resultCount > 1;
    return Padding(
      // Owns the status-bar inset, because it is now the top of the screen.
      // It used to sit *under* the header, which held that inset for both of
      // them — once search started replacing the header instead of stacking
      // below it, nothing was left holding the bar clear of the clock.
      padding:
          EdgeInsets.fromLTRB(8, MediaQuery.paddingOf(context).top + 4, 8, 4),
      child: _HeaderPill(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                textInputAction: TextInputAction.search,
                style: TextStyle(
                  color: AppColors.textOnGlass,
                  fontSize: 14,
                ),
                decoration: InputDecoration(
                  hintText: t.chatSearchHint,
                  hintStyle: TextStyle(color: AppColors.textOnGlassDim),
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    color: AppColors.brandPrimary,
                    size: 19,
                  ),
                  prefixIconConstraints:
                      const BoxConstraints(minWidth: 34, minHeight: 34),
                  border: InputBorder.none,
                  isDense: true,
                ),
                onChanged: (value) {
                  setState(() => _query = value);
                  widget.onChanged(value);
                },
              ),
            ),
            Text(
              counter,
              style: TextStyle(
                color: widget.resultIndex == null && _query.trim().isNotEmpty
                    ? AppColors.textOnGlassDim
                    : AppColors.brandPrimary,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            _SearchIconButton(
              icon: Icons.keyboard_arrow_up_rounded,
              tooltip: t.chatSearchPrevious,
              onPressed: canNavigate ? widget.onPrevious : null,
            ),
            _SearchIconButton(
              icon: Icons.keyboard_arrow_down_rounded,
              tooltip: t.chatSearchNext,
              onPressed: canNavigate ? widget.onNext : null,
            ),
            _SearchIconButton(
              icon: Icons.close_rounded,
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              onPressed: widget.onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// The header while messages are ticked: how many, and the two things you can
/// do with them.
///
/// Sits where the identity pill and the search bar sit, for the same reason —
/// stacking it under them would push the conversation you are selecting from
/// off the screen.
class _ChatSelectionBar extends StatelessWidget {
  const _ChatSelectionBar({
    required this.count,
    required this.onCancel,
    required this.onForward,
    required this.onDelete,
  });

  final int count;
  final VoidCallback onCancel;
  final VoidCallback onForward;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding:
          EdgeInsets.fromLTRB(8, MediaQuery.paddingOf(context).top + 4, 8, 4),
      child: _HeaderPill(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            _SearchIconButton(
              icon: Icons.close_rounded,
              tooltip: MaterialLocalizations.of(context).cancelButtonLabel,
              onPressed: onCancel,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                t.chatSelectedCount(count),
                style: TextStyle(
                  color: AppColors.textOnGlass,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            _PillIconButton(
              icon: Icons.shortcut_outlined,
              color: AppColors.textOnGlass,
              tooltip: t.chatForwardAction,
              onPressed: onForward,
            ),
            _PillIconButton(
              icon: Icons.delete_outline,
              color: AppColors.danger,
              tooltip: t.chatDeleteAction,
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchIconButton extends StatelessWidget {
  const _SearchIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon, size: 20),
      color: AppColors.textOnGlass,
      disabledColor: AppColors.textOnGlassFaint,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 32, height: 34),
    );
  }
}

/// The pinned-message island under the header. Tapping it jumps to that
/// message *and* moves the bar up to the next pin; the button on the right
/// clears the pin for both sides.
///
/// Built as its own floating pane rather than a strip welded under the app bar,
/// so it belongs to the same family as the header pills, the bubbles and the
/// nav bar. The marker rail on the left and the media thumbnail are what make it
/// legible at a glance: with a photo pinned, the picture *is* the label.
class _PinnedBar extends StatelessWidget {
  const _PinnedBar({
    required this.message,
    required this.index,
    required this.count,
    required this.onTap,
    required this.onUnpin,
  });

  final Message message;
  final VoidCallback onTap;
  final VoidCallback onUnpin;

  /// Position of the shown pin in the conversation, oldest first.
  final int index;
  final int count;

  /// Side of the square media thumbnail.
  static const double _thumb = 34;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final String preview;
    switch (message.kind) {
      case MessageKind.image:
        // The thumbnail carries the "it's a photo" part, so the line beside it
        // is free for the caption — or, failing that, a plain label.
        final caption = message.text.trim();
        preview = _looksLikeMime(caption) ? 'рџ“· Photo' : caption;
      case MessageKind.audio:
        preview = 'рџЋ¤ Voice message';
      case MessageKind.file:
        preview = 'рџ“Ћ ${message.fileName ?? 'File'}';
      case MessageKind.poll:
        preview = 'рџ“Љ ${message.text}';
      case MessageKind.text:
        preview = message.text.replaceAll('\n', ' ').trim();
    }

    final path = message.imagePath;
    final thumb = (message.kind == MessageKind.image &&
            path != null &&
            File(path).existsSync())
        ? ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(path),
              width: _thumb,
              height: _thumb,
              fit: BoxFit.cover,
              // A pinned photo whose cache file went missing must not take the
              // whole header down with it.
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          )
        : null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: GestureDetector(
        onTap: onTap,
        // Same glass as the composer and the header capsule, so the three read
        // as one family of islands floating over the conversation rather than
        // three different treatments stacked down the screen.
        child: MessageIslandGlass(
          borderRadius: 20,
          padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
          child: Row(
            children: [
              _PinRail(index: index, count: count),
              const SizedBox(width: 10),
              if (thumb != null) ...[thumb, const SizedBox(width: 10)],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      count > 1
                          ? '${t.chatPinnedTitle} ${index + 1}/$count'
                          : t.chatPinnedTitle,
                      style: TextStyle(
                        color: AppColors.brandPrimary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textOnGlass,
                        fontSize: 12.5,
                        height: 1.15,
                      ),
                    ),
                  ],
                ),
              ),
              _PillIconButton(
                icon: Icons.push_pin_outlined,
                color: AppColors.textOnGlassDim,
                tooltip: t.chatUnpinAction,
                onPressed: onUnpin,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Media bubbles carry the mime type in [Message.text] when there's no real
  /// caption, and "image/jpeg" is not a preview worth showing.
  static bool _looksLikeMime(String s) =>
      s.isEmpty || s.startsWith('image/') || s.startsWith('audio/');
}

/// Telegram's pin rail: one segment per pinned message, the shown one lit.
///
/// It is the only thing that says how far up the stack a tap has taken you
/// without reading the counter, which matters because tapping the bar is now
/// how you walk through the pins — the rail is the progress bar for that walk.
class _PinRail extends StatelessWidget {
  const _PinRail({required this.index, required this.count});

  final int index;
  final int count;

  /// Above this the segments are thinner than the gaps between them and the
  /// rail stops reading as anything. Twenty pins is the storage ceiling, so
  /// past the cap it degrades to a plain marker rather than a smear.
  static const int _maxSegments = 8;

  @override
  Widget build(BuildContext context) {
    const height = _PinnedBar._thumb;
    final dim = AppColors.brandPrimary.withValues(alpha: .28);
    if (count < 2 || count > _maxSegments) {
      return Container(
        width: 2.5,
        height: height,
        decoration: BoxDecoration(
          color: AppColors.brandPrimary,
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }
    const gap = 2.0;
    final segment = (height - gap * (count - 1)) / count;
    return SizedBox(
      width: 2.5,
      height: height,
      child: Column(
        children: [
          // Oldest pin at the top, matching the conversation it indexes.
          for (var i = 0; i < count; i++) ...[
            if (i > 0) const SizedBox(height: gap),
            Container(
              width: 2.5,
              height: segment,
              decoration: BoxDecoration(
                color: i == index ? AppColors.brandPrimary : dim,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Message list with the composer floating clear of the bottom edge, the
/// conversation scrolling underneath it — the same principle as the floating
/// nav bar, rather than a bar welded across the foot of the screen.
///
/// The list needs bottom room equal to the composer's height, or the newest
/// message sits behind it. That height is not a constant: the input grows with
/// multi-line text and gains a "Replying to …" bar above it. So the composer is
/// measured after layout and the padding follows it, instead of guessing a
/// number that would be wrong exactly when someone is typing a long message.
class _FloatingComposerBody extends StatefulWidget {
  const _FloatingComposerBody({
    required this.listBuilder,
    required this.composer,
    required this.header,
    this.scrollToBottom,
  });

  /// Builds the conversation, given the padding that keeps it clear of the two
  /// floating islands.
  final Widget Function(EdgeInsets padding) listBuilder;

  /// Null while the newest message is already on screen — see the call site.
  final VoidCallback? scrollToBottom;
  final Widget composer;

  /// The header stack — identity capsule and, when there is one, the pinned
  /// island. Floats over the conversation exactly as the composer does.
  final Widget header;

  @override
  State<_FloatingComposerBody> createState() => _FloatingComposerBodyState();
}

class _FloatingComposerBodyState extends State<_FloatingComposerBody> {
  final _composerKey = GlobalKey();
  final _headerKey = GlobalKey();

  /// Heights used until the first real measurement lands — a single-line
  /// composer, and a header with no pinned bar. Only ever wrong for one frame.
  static const double _initialComposerGuess = 76;
  static const double _initialHeaderGuess = 72;

  /// Breathing room between the outermost message and the island beyond it.
  static const double _clearance = 12;

  double _composerHeight = _initialComposerGuess;
  double _headerHeight = _initialHeaderGuess;

  void _measure(Duration _) {
    _measureOne(_composerKey, _composerHeight, (h) => _composerHeight = h);
    _measureOne(_headerKey, _headerHeight, (h) => _headerHeight = h);
  }

  void _measureOne(GlobalKey key, double current, void Function(double) apply) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final h = box.size.height;
    // Sub-pixel churn would otherwise setState on every frame.
    if ((h - current).abs() < 0.5) return;
    setState(() => apply(h));
  }

  @override
  Widget build(BuildContext context) {
    // Re-measured after each build because both islands change height: the
    // composer grows with multi-line text and the reply bar, the header gains
    // and loses the pinned bar. The guard above makes the steady state a no-op.
    WidgetsBinding.instance.addPostFrameCallback(_measure);

    return Stack(
      children: [
        // reverse: true means the list starts at the visual bottom, so `bottom`
        // is what the newest message clears the composer by and `top` is what
        // the oldest clears the header by. Both islands float over the
        // conversation rather than occupying a band of their own, so the chat
        // stays visible behind them right to the edges of the screen.
        widget.listBuilder(
          EdgeInsets.only(
            top: _headerHeight + _clearance,
            bottom: _composerHeight + _clearance,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: _RemeasureOnResize(
            onResize: () =>
                WidgetsBinding.instance.addPostFrameCallback(_measure),
            child: KeyedSubtree(key: _headerKey, child: widget.header),
          ),
        ),
        // Only once there is somewhere to go. The list is reversed, so being
        // at the newest message means offset ~0 — showing the button there
        // would be a control that does nothing, parked over the conversation.
        if (widget.scrollToBottom != null)
          Positioned(
            right: 16,
            bottom: _composerHeight + _clearance + 8,
            child: _ScrollToBottomButton(onTap: widget.scrollToBottom!),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _RemeasureOnResize(
            onResize: () =>
                WidgetsBinding.instance.addPostFrameCallback(_measure),
            child: KeyedSubtree(key: _composerKey, child: widget.composer),
          ),
        ),
      ],
    );
  }
}

/// Calls back whenever [child] changes size, even without a rebuild here.
///
/// The islands are measured in a post-frame callback scheduled from this
/// widget's build — which was enough while they appeared and vanished in one
/// frame, and stopped being enough the moment they started animating: an
/// [AnimatedSize] relayouts without rebuilding its ancestors, so the padding
/// under it would hold the height the header had when the animation *started*
/// until something unrelated rebuilt the screen. This notices the layout
/// instead of the build.
class _RemeasureOnResize extends StatelessWidget {
  const _RemeasureOnResize({required this.onResize, required this.child});

  final VoidCallback onResize;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        onResize();
        return false;
      },
      child: SizeChangedLayoutNotifier(child: child),
    );
  }
}

class _ChatBottomBar extends ConsumerStatefulWidget {
  const _ChatBottomBar({
    required this.peerId,
    required this.canonicalId,
    required this.canSend,
    this.isChannel = false,
  });

  final String peerId;
  final String canonicalId;
  final bool canSend;
  final bool isChannel;

  @override
  ConsumerState<_ChatBottomBar> createState() => _ChatBottomBarState();
}

class _ChatBottomBarState extends ConsumerState<_ChatBottomBar> {
  Timer? _tick;
  Duration _elapsed = Duration.zero;

  /// True while a voice recording runs hands-free after the finger slid up.
  /// Cleared by whatever ends the recording, so the next hold starts held.
  bool _recordLocked = false;

  /// A finished locked recording waiting to be trimmed and sent. While this is
  /// set the composer is replaced by the trim island, so there is no way to
  /// start a second recording on top of an unreviewed one.
  PendingVoice? _pendingVoice;

  void _showAttachmentFailure(Object error) {
    final t = AppLocalizations.of(context);
    // Also into the log, not just the toast. A toast is gone in three seconds
    // and takes the only description of the failure with it, which is why
    // "sending files doesn't work" keeps arriving without the error attached.
    DebugLog.instance.log('ATTACH', 'send failed: $error');
    showGlassToast(
      context,
      error is MediaRouteUnavailable ? t.chatAttachmentUnavailable : '$error',
      tone: ToastTone.danger,
    );
  }

  @override
  void initState() {
    super.initState();
    // Mark this chat as the one the user is viewing, so inbound messages
    // for it don't pop a (redundant) notification. Clears any banner too.
    AppLifecycle.instance.activeChatId = widget.canonicalId;
    NotificationService.instance.clearForChat(widget.canonicalId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _markChatRead();
      _maybeSendReadReceipts();
      _maybeAnnounceCopyRestriction();
    });
    // Drop any inline-edit draft left over from a different chat. Deferred so
    // we don't mutate a provider during this widget's mount.
    final stale = ref.read(messageEditTargetProvider);
    if (stale != null && stale.chatId != widget.canonicalId) {
      Future.microtask(() {
        if (!mounted) return;
        ref.read(messageEditTargetProvider.notifier).state = null;
      });
    }
  }

  /// Acknowledge the messages as read now that the user is looking at them.
  ///
  /// Channels included: the receipt goes out under the channel key rather than
  /// sealed to one peer, so every member learns who has caught up. Which member
  /// sent it comes from the frame's signature, not from the payload.
  void _maybeSendReadReceipts() {
    if (!mounted) return;
    ref.read(messagingServiceProvider).sendReadReceipts(widget.canonicalId);
  }

  /// Say again, at most once per peer per app run, that this conversation is
  /// not to be copied or forwarded.
  ///
  /// The notice has no acknowledgement, so a peer who was offline when the
  /// switch was thrown would never have heard. Opening the chat is a moment
  /// they are plausibly reachable, and the service drops the repeat itself
  /// (see [MessagingService.announceCopyRestriction]) — nothing goes out for a
  /// conversation that never restricted anything.
  void _maybeAnnounceCopyRestriction() {
    if (!mounted || widget.isChannel) return;
    unawaited(
      ref
          .read(messagingServiceProvider)
          .announceCopyRestriction(widget.canonicalId),
    );
  }

  /// Advance this chat's local read marker so its unread badge clears on the
  /// main Chats list.
  void _markChatRead() {
    if (!mounted) return;
    ref
        .read(readMarkersControllerProvider.notifier)
        .markRead(widget.canonicalId);
  }

  @override
  void didUpdateWidget(covariant _ChatBottomBar old) {
    super.didUpdateWidget(old);
    // Opened from Nearby, the canonical id starts as the BLE transport id and
    // flips to the peer's pubkey-hex once the handshake completes — without
    // re-running initState. Keep the active-chat marker in sync so inbound
    // messages for this (now pubkey-keyed) chat still suppress notifications.
    if (old.canonicalId != widget.canonicalId) {
      if (AppLifecycle.instance.activeChatId == old.canonicalId) {
        AppLifecycle.instance.activeChatId = widget.canonicalId;
      }
      NotificationService.instance.clearForChat(widget.canonicalId);
      _markChatRead();
      _maybeSendReadReceipts();
    }
  }

  void _startTicker() {
    _tick?.cancel();
    _elapsed = Duration.zero;
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final st = ref.read(voiceRecorderProvider);
      if (!st.isRecording || st.startedAt == null) {
        _stopTicker();
        return;
      }
      if (!mounted) return;
      setState(() {
        _elapsed = DateTime.now().difference(st.startedAt!);
      });
    });
  }

  void _stopTicker() {
    _tick?.cancel();
    _tick = null;
    if (mounted) setState(() => _elapsed = Duration.zero);
  }

  @override
  void dispose() {
    _tick?.cancel();
    // Only clear if we're still the active chat — guards against the
    // next chat's initState having already set itself during a transition.
    if (AppLifecycle.instance.activeChatId == widget.canonicalId) {
      AppLifecycle.instance.activeChatId = null;
    }
    super.dispose();
  }

  Future<void> _onRecordStart() async {
    if (mounted) setState(() => _recordLocked = false);
    final ok = await ref.read(voiceRecorderProvider.notifier).start();
    if (!ok) {
      if (!mounted) return;
      final err = ref.read(voiceRecorderProvider).error ?? 'cannot record';
      showGlassToast(context, err, tone: ToastTone.danger);
      return;
    }
    _startTicker();
  }

  /// Under this, a press was a mis-tap rather than a message.
  ///
  /// The mic arms almost on touch-down now, which is what makes it feel like
  /// Telegram's — and also means a stray tap on the composer would otherwise
  /// fire off a quarter-second of room noise. Locked recordings are exempt:
  /// the finger is long gone and the length is deliberate.
  static const _minVoiceMs = 500;

  Future<void> _onRecordStop() async {
    final wasLocked = _recordLocked;
    final result = await ref.read(voiceRecorderProvider.notifier).stop();
    _stopTicker();
    if (mounted) setState(() => _recordLocked = false);
    if (result == null) return;
    if (!wasLocked && result.durationMs < _minVoiceMs) {
      unawaited(_discardRecording(result.path));
      if (mounted) {
        showGlassToast(context, AppLocalizations.of(context).voiceHoldHint);
      }
      return;
    }
    if (!widget.canSend) return;

    // A locked recording gets a review step: the finger is already off the
    // button and the user is looking at the screen, so this is the moment to
    // offer a trim. A held press that was just released does not — that
    // gesture exists to be fast, and an editor in the way would make the
    // common case slower to serve the rare one.
    if (wasLocked && mounted) {
      setState(() {
        _pendingVoice = PendingVoice(
          path: result.path,
          durationMs: result.durationMs,
          envelope: result.envelope,
        );
      });
      return;
    }

    await _sendVoice(
      path: result.path,
      durationMs: result.durationMs,
    );
  }

  /// Bin a recording that is never going to be sent. Cache files are small and
  /// the directory is disposable, but a mic that starts on every stray tap
  /// would otherwise leave one behind each time.
  Future<void> _discardRecording(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Read the file and put it on the wire. [path] is whatever survived
  /// trimming — the trimmer falls back to the original recording, so this is
  /// never handed a missing file because a cut failed.
  Future<void> _sendVoice({
    required String path,
    required int durationMs,
  }) async {
    try {
      // Notes to yourself have no other end, so nothing goes on the wire —
      // every media path used to reach for a recipient pubkey and throw
      // "no recipient pubkey for @saved" at the one chat that cannot have one.
      if (isSavedChat(widget.canonicalId)) {
        await ref
            .read(savedMessagesControllerProvider)
            .saveVoice(File(path), durationMs: durationMs);
        return;
      }
      final bytes = await File(path).readAsBytes();
      await ref.read(messagingServiceProvider).sendAudio(
            widget.peerId,
            bytes: bytes,
            mime: 'audio/aac',
            durationMs: durationMs,
            cachedPath: path,
          );
    } catch (e) {
      if (!mounted) return;
      _showAttachmentFailure(e);
    }
  }

  /// Commit the reviewed recording, cutting it to the chosen range first.
  Future<void> _sendTrimmedVoice(int startMs, int endMs) async {
    final pending = _pendingVoice;
    if (pending == null) return;
    setState(() => _pendingVoice = null);

    final path = await AudioTrimmer().trimOrOriginal(
      sourcePath: pending.path,
      startMs: startMs,
      endMs: endMs,
      fullDurationMs: pending.durationMs,
    );
    // Only claim the trimmed length when the cut actually happened.
    final durationMs =
        path == pending.path ? pending.durationMs : endMs - startMs;
    await _sendVoice(path: path, durationMs: durationMs);
  }

  /// Throw the reviewed recording away.
  Future<void> _discardPendingVoice() async {
    final pending = _pendingVoice;
    setState(() => _pendingVoice = null);
    if (pending == null) return;
    try {
      final f = File(pending.path);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // A leftover file in the cache directory is not worth surfacing.
    }
  }

  Future<void> _onRecordCancel() async {
    await ref.read(voiceRecorderProvider.notifier).cancel();
    _stopTicker();
    if (mounted) setState(() => _recordLocked = false);
  }

  Future<void> _pickAndSendImage() async {
    // Custom in-app picker: a photo grid (multi-select) with a camera tile.
    final result = await showGlassSheet<MediaPickerResult>(
      context: context,
      builder: (_) => MediaPickerSheet(
        allowFiles: !widget.isChannel,
        allowPoll: widget.isChannel && !isSavedChat(widget.canonicalId),
      ),
    );
    if (result == null || !mounted) return;

    switch (result) {
      case MediaPickerFile():
        await _pickAndSendFile();
      case MediaPickerCamera():
        await _captureEditAndSend();
      case MediaPickerPoll():
        await showChannelPollComposer(context, ref, widget.peerId);
      case MediaPickerAssets(:final assets):
        if (assets.isEmpty) return;
        await _previewAndSend(assets);
    }
  }

  /// Файл category → the platform document picker → send as-is.
  ///
  /// Nothing is re-encoded or downscaled on this path: a file is whatever the
  /// sender chose, byte for byte, and the receiver checks it against the
  /// manifest's signed hash. That is the whole difference from the photo path,
  /// which shrinks its input to fit the mesh.
  Future<void> _pickAndSendFile() async {
    final t = AppLocalizations.of(context);
    final picked = await FilePicker.platform.pickFiles(withReadStream: false);
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;

    try {
      final name = picked!.files.single.name;
      if (isSavedChat(widget.canonicalId)) {
        await ref.read(savedMessagesControllerProvider).saveFile(
              File(path),
              fileName: name,
              mime: fileMimeType(name),
            );
        return;
      }
      await ref.read(messagingServiceProvider).sendFile(
            widget.canonicalId,
            file: File(path),
            fileName: name,
            mime: fileMimeType(name),
          );
    } on FileTooLarge catch (e) {
      // The two ceilings are far apart, and which one was hit changes the
      // advice: over the relay the same file may well go once they are in
      // Bluetooth range.
      if (mounted) {
        // The number comes off the exception, so the advice and the ceiling
        // that produced it cannot drift apart.
        final limit = e.cap ~/ (1024 * 1024);
        showGlassToast(
          context,
          e.relayOnly ? t.fileTooLargeRelay(limit) : t.fileTooLargeMesh(limit),
          tone: ToastTone.danger,
        );
      }
    } catch (e) {
      if (mounted) {
        _showAttachmentFailure(e);
      }
    }
  }

  /// Gallery pick в†’ preview with a caption в†’ send.
  ///
  /// Both the single pick and the batch come through here now. The old flow
  /// forced the editor open for one photo and skipped straight to sending for
  /// several, which meant the two cases behaved nothing alike and neither gave
  /// a chance to look at what was about to go out.
  Future<void> _previewAndSend(List<AssetEntity> assets) async {
    // Bounded-resolution copies: the preview only has to look right on screen,
    // and the mesh encoder downscales again afterwards anyway.
    final loaded = <Uint8List>[];
    for (final a in assets) {
      final bytes = await a.thumbnailDataWithSize(
        const ThumbnailSize(1600, 1600),
        quality: 90,
      );
      if (bytes != null) loaded.add(bytes);
    }
    if (loaded.isEmpty || !mounted) return;

    final result = await Navigator.of(context).push<MediaPreviewResult>(
      mediaRoute<MediaPreviewResult>(
        (_) => MediaPreviewScreen(
          items: loaded,
          allowOriginal: !widget.isChannel,
          allowViewOnce:
              !widget.isChannel && !isSavedChat(widget.canonicalId),
        ),
      ),
    );
    if (result == null || !mounted) return;

    if (result.asFile) {
      await _sendOriginals(assets, caption: result.caption);
      return;
    }

    for (var i = 0; i < result.bytes.length; i++) {
      // The caption belongs to the set, not to each photo — repeating it under
      // every picture in a batch would read as a stutter. It goes on the first.
      await _encodeAndSend(
        result.bytes[i],
        '${assets[i].id}-${DateTime.now().microsecondsSinceEpoch}',
        caption: i == 0 ? result.caption : null,
        viewOnce: result.viewOnce,
      );
      if (!mounted) return;
    }
  }

  /// The picked photos, sent as they sit in the gallery.
  ///
  /// The ordinary photo path downscales and re-encodes to fit a picture through
  /// Bluetooth, which is right for a snapshot and wrong for a document you
  /// photographed to be read — the text is the first thing the encoder spends.
  /// This one hands the asset's own file to [MessagingService.sendFile], the
  /// same route the document picker uses, so the bytes that arrive are the
  /// bytes that left and the receiver checks them against the signed hash.
  ///
  /// A caption follows as its own message: a file carries its mime type where a
  /// photo carries a caption, and there is nowhere in the manifest to put one.
  Future<void> _sendOriginals(
    List<AssetEntity> assets, {
    String? caption,
  }) async {
    final t = AppLocalizations.of(context);
    final messaging = ref.read(messagingServiceProvider);
    var sent = 0;
    for (final asset in assets) {
      try {
        final origin = await asset.originFile;
        if (origin == null || !mounted) continue;
        final name = await asset.titleAsync;
        final safe = name.trim().isEmpty
            ? 'photo-${asset.id}.jpg'
            : name;
        if (isSavedChat(widget.canonicalId)) {
          await ref.read(savedMessagesControllerProvider).saveFile(
                origin,
                fileName: safe,
                mime: fileMimeType(safe),
              );
          sent++;
          continue;
        }
        await messaging.sendFile(
          widget.canonicalId,
          file: origin,
          fileName: safe,
          mime: fileMimeType(safe),
        );
        sent++;
      } on FileTooLarge catch (e) {
        if (!mounted) return;
        final limit = e.cap ~/ (1024 * 1024);
        showGlassToast(
          context,
          e.relayOnly ? t.fileTooLargeRelay(limit) : t.fileTooLargeMesh(limit),
          tone: ToastTone.danger,
        );
        return;
      } catch (e) {
        if (!mounted) return;
        _showAttachmentFailure(e);
        return;
      }
    }
    if (!mounted) return;
    if (sent > 0 && caption != null) {
      await messaging.sendText(widget.peerId, caption);
    }
  }

  /// Camera tile в†’ in-app capture в†’ editor в†’ send.
  Future<void> _captureEditAndSend() async {
    final captured = await Navigator.of(context).push<Uint8List>(
      mediaRoute<Uint8List>((_) => const CameraCaptureScreen()),
    );
    if (captured == null || !mounted) return;
    await _editAndSendBytes(
      captured,
      idHint: 'cam-${DateTime.now().millisecondsSinceEpoch}',
    );
  }

  Future<void> _editAndSendBytes(
    Uint8List source, {
    required String idHint,
  }) async {
    final edited = await openImageEditor(context, source);
    if (edited == null || !mounted) return; // backed out of the editor
    await _encodeAndSend(edited, idHint);
  }

  /// Downscale arbitrary (camera / edited) bytes to the mesh budget and send.
  Future<void> _encodeAndSend(
    Uint8List bytes,
    String idHint, {
    String? caption,
    bool viewOnce = false,
  }) async {
    try {
      final wire = await encodeBytesForMesh(bytes);
      if (!mounted) return;
      if (wire == null) {
        showGlassToast(context, 'Image too large to send',
            tone: ToastTone.danger);
        return;
      }
      await _sendImageBytes(
        wire,
        idHint,
        caption: caption,
        viewOnce: viewOnce,
      );
    } catch (e) {
      if (!mounted) return;
      _showAttachmentFailure(e);
    }
  }

  /// Cache the outgoing bytes (so our own bubble renders at once) and hand them
  /// to the transport.
  Future<void> _sendImageBytes(
    Uint8List bytes,
    String idHint, {
    String? caption,
    bool viewOnce = false,
  }) async {
    if (isSavedChat(widget.canonicalId)) {
      await ref
          .read(savedMessagesControllerProvider)
          .saveImage(bytes, caption: caption);
      return;
    }
    final messaging = ref.read(messagingServiceProvider);
    final cachedPath = await _cacheOutgoingImage(bytes, idHint);
    if (widget.isChannel) {
      await messaging.sendChannelImage(
        widget.peerId,
        bytes: bytes,
        mime: 'image/jpeg',
        cachedPath: cachedPath,
        caption: caption,
      );
      return;
    }
    await messaging.sendImage(
      widget.peerId,
      bytes: bytes,
      mime: 'image/jpeg',
      cachedPath: cachedPath,
      caption: caption,
      viewOnce: viewOnce,
    );
  }

  /// Persist the downscaled bytes we're about to send to the app cache, so the
  /// sender's own bubble can render the image immediately (the picker gives us
  /// bytes, not a stable file path).
  Future<String?> _cacheOutgoingImage(Uint8List bytes, String assetId) async {
    try {
      // Persistent, not cache — see [mediaDirectory]. This copy is the only
      // one an outgoing bubble has to render from.
      final dir = await sentImagesDirectory();
      final safeId = assetId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final file = File('${dir.path}/$safeId.jpg');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return null; // preview is best-effort; the send still goes through
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final voiceState = ref.watch(voiceRecorderProvider);
    final draft = ref.watch(draftsControllerProvider)[widget.canonicalId];
    // A new inbound message while the chat is open should be acknowledged and
    // counted as read (so its badge never appears on the list behind us).
    ref.listen(messagesControllerProvider, (_, __) {
      _markChatRead();
      _maybeSendReadReceipts();
    });
    // And again when a link comes back. A receipt composed while the peer was
    // unreachable is no longer recorded as sent (see [sendReadReceipts]), so it
    // is waiting to be retried — but nothing would retry it while the chat sits
    // open and no new message arrives, which is exactly the case where somebody
    // is watching the other person's tick fail to turn over.
    ref.listen(chatSessionManagerProvider, (_, __) => _maybeSendReadReceipts());
    ref.listen(relayStatusProvider, (_, __) => _maybeSendReadReceipts());
    // Voice notes are still 1:1: a room relays every chunk through every
    // member, so the cost of an attachment there is paid by everyone. Photos
    // are worth that and are capped by the picker; see
    // [MessagingService.sendChannelImage].
    final mediaEnabled = widget.canSend && !widget.isChannel;
    final photosEnabled = widget.canSend;

    // Inline edit: only when the target belongs to THIS chat.
    final editTarget = ref.watch(messageEditTargetProvider);
    final editingText =
        (editTarget != null && editTarget.chatId == widget.canonicalId)
            ? editTarget.originalText
            : null;

    // Reply compose (1:1 only for now — channels display quotes but don't
    // compose them yet).
    final replyTargetRaw =
        widget.isChannel ? null : ref.watch(messageReplyTargetProvider);
    final activeReply =
        (replyTargetRaw != null && replyTargetRaw.chatId == widget.canonicalId)
            ? replyTargetRaw
            : null;

    final composer = ChatInput(
      hint: t.chatInputHint,
      sendTooltip: t.chatSend,
      editingText: editingText,
      initialText: draft?.text,
      onChanged: (text) {
        ref
            .read(draftsControllerProvider.notifier)
            .update(widget.canonicalId, text);
        // Throttled inside the service, so this can fire on every keystroke.
        // An emptied composer says so at once — that is the frame that ends
        // the indicator early instead of waiting out its TTL.
        if (!widget.isChannel && !isSavedChat(widget.canonicalId)) {
          unawaited(ref.read(messagingServiceProvider).announceTyping(
                widget.canonicalId,
                typing: text.trim().isNotEmpty,
              ));
        }
      },
      onEditCancel: () =>
          ref.read(messageEditTargetProvider.notifier).state = null,
      onEditCommit: (newText) async {
        final target = ref.read(messageEditTargetProvider);
        ref.read(messageEditTargetProvider.notifier).state = null;
        if (target == null) return;
        await ref
            .read(messagingServiceProvider)
            .sendEdit(target.chatId, target.wireId, newText);
      },
      onAttach:
          photosEnabled && !voiceState.isRecording ? _pickAndSendImage : null,
      onRecordStart: mediaEnabled ? _onRecordStart : null,
      onRecordStop: mediaEnabled ? _onRecordStop : null,
      onRecordCancel: mediaEnabled ? _onRecordCancel : null,
      onRecordLock:
          mediaEnabled ? () => setState(() => _recordLocked = true) : null,
      recordLocked: _recordLocked,
      recording: voiceState.isRecording,
      recordElapsed: _elapsed,
      recordLevels: voiceState.levels,
      onSend: (text) async {
        final result =
            await CommandProcessor(ref, widget.canonicalId).tryExecute(text);
        if (result != null) {
          if (!mounted) return;
          showGlassToast(
            context,
            result.message,
            tone: result.success ? ToastTone.success : ToastTone.danger,
            // Multi-line command output needs longer than a one-word ack.
            duration: Duration(
              seconds: result.message.contains('\n') ? 5 : 2,
            ),
          );
          return;
        }
        if (!widget.canSend) return;
        // Consume the reply target now so the bar clears the moment we send.
        final replyWireId = activeReply?.wireId;
        if (replyWireId != null) {
          ref.read(messageReplyTargetProvider.notifier).state = null;
        }
        try {
          if (isSavedChat(widget.peerId)) {
            // Nowhere to send it: this conversation has no other end.
            await ref.read(savedMessagesControllerProvider).saveText(text);
          } else if (widget.isChannel) {
            await ref
                .read(messagingServiceProvider)
                .sendChannelText(widget.peerId, text);
          } else {
            await ref
                .read(messagingServiceProvider)
                .sendText(widget.peerId, text, replyToWireId: replyWireId);
          }
        } catch (e) {
          if (!mounted) return;
          showGlassToast(context, '$e', tone: ToastTone.danger);
        }
      },
    );

    // A recording waiting to be reviewed takes the composer's place entirely.
    // Leaving the input underneath would invite starting a second recording,
    // or typing, on top of one that has not been dealt with.
    // Three ways this goes: a room offers its roster, a 1:1 offers the one
    // person it has, and a notebook offers nobody — there is no one there to
    // mention.
    final Widget composerWithMentions;
    if (widget.isChannel) {
      composerWithMentions = MentionSuggestions(
        channelName: widget.canonicalId,
        text: draft?.text ?? '',
        onTextChanged: (text) => ref
            .read(draftsControllerProvider.notifier)
            .update(widget.canonicalId, text),
        child: composer,
      );
    } else if (isSavedChat(widget.canonicalId)) {
      composerWithMentions = composer;
    } else {
      final peer = ref.watch(knownPeersControllerProvider)[widget.canonicalId];
      final aliases = ref.watch(contactAliasesControllerProvider);
      composerWithMentions = DirectMentionHint(
        peerName: peer == null
            ? ''
            : contactDisplayName(
                alias: aliases[peer.pubkeyHex],
                rawBroadcastName: peer.displayName,
                pubkeyHex: peer.pubkeyHex,
              ),
        text: draft?.text ?? '',
        onTextChanged: (text) => ref
            .read(draftsControllerProvider.notifier)
            .update(widget.canonicalId, text),
        child: composer,
      );
    }

    final pending = _pendingVoice;
    if (pending != null) {
      return VoiceTrimBar(
        pending: pending,
        onCancel: _discardPendingVoice,
        onSend: (startMs, endMs) => unawaited(
          _sendTrimmedVoice(startMs, endMs),
        ),
      );
    }

    if (activeReply == null) return composerWithMentions;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReplyComposeBar(
          target: activeReply,
          onCancel: () =>
              ref.read(messageReplyTargetProvider.notifier).state = null,
        ),
        composerWithMentions,
      ],
    );
  }
}

/// The little "Replying to …" bar shown above the input while composing a
/// reply. Cancel clears the reply target.
class _ReplyComposeBar extends StatelessWidget {
  const _ReplyComposeBar({required this.target, required this.onCancel});

  final MessageReplyTarget target;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final String header;
    if (target.mine) {
      header = t.chatReplyingTo(t.chatReplyYou);
    } else if (target.authorName != null) {
      header = t.chatReplyingTo(target.authorName!);
    } else {
      header = t.chatReplyAction; // 1:1 peer — a plain "Reply".
    }
    // Its own island, not a strip fused to the top of the composer: the same
    // glass, radius and side margins, so the quote reads as a card you can
    // dismiss rather than as part of the input box.
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: MessageIslandGlass(
        borderRadius: 20,
        padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
        child: Row(
          children: [
            // Same marker rail as the pinned island — a quoted line is quoted
            // the same way wherever it appears.
            Container(
              width: 2.5,
              height: 30,
              decoration: BoxDecoration(
                color: AppColors.brandPrimary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    header,
                    style: TextStyle(
                      color: AppColors.brandPrimary,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    target.preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textOnGlass,
                      fontSize: 12.5,
                      height: 1.15,
                    ),
                  ),
                ],
              ),
            ),
            _PillIconButton(
              icon: Icons.close,
              color: AppColors.textOnGlassDim,
              tooltip: t.cancel,
              onPressed: onCancel,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyConversationState extends StatelessWidget {
  const _EmptyConversationState({required this.canSend});

  final bool canSend;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              canSend ? Icons.lock_outline : Icons.hourglass_top,
              color:
                  canSend ? AppColors.brandPrimary : AppColors.textOnGlassFaint,
              size: 36,
            ),
            const SizedBox(height: 12),
            Text(
              canSend ? t.chatEmptyEstablished : t.chatEmptyHandshaking,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

/// The mark beside a peer's name saying whether their key has been checked.
///
/// Was a shield button out at the end of the header row, which read as a third
/// control next to Search and Back and invited a tap that only ever led to the
/// same place the name already leads. Verification is a fact about the person,
/// so it belongs on the person: three states, no tap of its own.
///
///   - nothing: handshake not finished, so there is no key to have verified
///   - dim shield: key known, fingerprints not yet compared
///   - green check: compared and confirmed
///   - amber warning: the signing key changed since — the one state loud
///     enough to interrupt, because it is the one that means something is off
class _VerificationMark extends StatelessWidget {
  const _VerificationMark({required this.session, required this.ref});

  final ChatSession? session;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final pubkeyHex = session?.remotePubkeyHex;
    if (pubkeyHex == null) return const SizedBox.shrink();

    final entry = ref.watch(knownPeersControllerProvider)[pubkeyHex];
    if (entry == null) return const SizedBox.shrink();

    final rotated = entry.hasUnacknowledgedRotation;
    final verified = entry.isVerified;
    if (!rotated && !verified) {
      return Tooltip(
        message: t.verifyTitle,
        child: Icon(Icons.shield_outlined,
            size: 13, color: AppColors.textOnGlassFaint),
      );
    }
    return Tooltip(
      message: rotated ? t.peerKeyRotated : t.verifyAlreadyDone,
      child: Icon(
        rotated ? Icons.gpp_maybe_rounded : Icons.verified_rounded,
        size: 14,
        color: rotated ? AppColors.danger : AppColors.brandPrimary,
      ),
    );
  }
}

/// Jump to the newest message.
///
/// Reading back through a long scrollback, the way out is otherwise a lot of
/// flinging — and in a conversation the newest message is where you almost
/// always want to end up.
class _ScrollToBottomButton extends StatelessWidget {
  const _ScrollToBottomButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FloatingGlass(
      borderRadius: 22,
      padding: EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        child: InkResponse(
          onTap: onTap,
          radius: 26,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(
              Icons.keyboard_double_arrow_down_rounded,
              color: AppColors.textOnGlass,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}
