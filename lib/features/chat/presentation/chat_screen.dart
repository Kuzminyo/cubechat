import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../../core/notifications/notification_service.dart';
import 'package:file_picker/file_picker.dart';
import '../../../core/transport/file_reassembly.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/transport/chat_session.dart';
import '../../../core/transport/chat_session_manager.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/transport/mtu_budget.dart';
import '../../../core/util/app_lifecycle.dart';
import '../../../core/util/audio_trimmer.dart';
import '../../../core/utils/time_format.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../peers/presentation/widgets/peer_avatar.dart';
import '../../../l10n/app_localizations.dart';
import '../../channels/data/channel_controller.dart';
import '../../chats/data/read_markers_controller.dart';
import '../../peers/data/known_peers_controller.dart';
import '../../peers/data/peer_discovery_controller.dart';
import '../../peers/data/presence_controller.dart';
import '../data/message_edit_target.dart';
import '../data/message_reply_target.dart';
import '../data/conversation_settings_controller.dart';
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
import 'widgets/voice_trim_bar.dart';
import '../../../core/widgets/glass_toast.dart';

/// True when [id] is a BLE device id (an Android MAC or an iOS UUID) rather
/// than the 64-char pubkey-hex the Chats list routes with. Only the former can
/// be handed to `BluetoothDevice.fromId` for a reconnect.
bool _isBleDeviceId(String id) =>
    !(id.length == 64 && RegExp(r'^[0-9a-f]+$').hasMatch(id));

/// Real-transport chat screen.
///
/// Identifies the conversation by `peerId` (the transport-level BLE id), reads
/// messages from [messagesControllerProvider], and dispatches sends to
/// [messagingServiceProvider]. The handshake state is reflected in the AppBar
/// subtitle so the user can tell whether their messages will actually go out.
class ChatScreen extends ConsumerWidget {
  const ChatScreen({super.key, required this.peerId, required this.peerLabel});

  final String peerId;
  final String peerLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final messagesMap = ref.watch(messagesControllerProvider);

    // Group channel (`#name`): no Noise session, no presence — membership is
    // just holding the shared key. Send is enabled while we're a member.
    if (peerId.startsWith('#')) {
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
    // Sending needs a recipient pubkey, not a live handshake. Gating on
    // isEstablished made Send a silent no-op whenever the peer wasn't a direct
    // BLE neighbour: two phones talking only over the internet could type but
    // nothing ever left the phone (no bubble, no error). Enable Send whenever we
    // can address the peer at all — sendText appends the bubble and it shows a
    // clock until a transport (mesh / Nostr / store-and-forward) takes it.
    final canSend = (session?.isEstablished ?? false) || known != null;

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
    final isOnline = peerIsOnline(
      hasLiveSession: session?.isEstablished ?? false,
      beacon: ref.watch(presenceControllerProvider)[canonicalId],
      lastSeen: lastSeen,
    );
    final String statusText;
    if (session != null &&
        (session.status == ChatSessionStatus.handshakingInitiator ||
            session.status == ChatSessionStatus.handshakingResponder ||
            session.status == ChatSessionStatus.idle)) {
      statusText = t.chatSessionHandshaking;
    } else if (session != null && session.status == ChatSessionStatus.failed) {
      statusText = t.chatSessionFailed;
    } else if (isOnline) {
      statusText = t.presenceOnline;
    } else if (lastSeen != null) {
      // "offline · 14:05" / "offline · Mon" — precise last-seen.
      statusText =
          '${t.presenceOffline} · ${formatChatListTime(context, lastSeen)}';
    } else {
      statusText = t.presenceOffline;
    }

    final pubkeyHex = session?.remotePubkeyHex ?? known?.pubkeyHex;

    return Scaffold(
      backgroundColor: Colors.transparent,
      // No AppBar: the header is an island floating over the conversation (see
      // _FloatingComposerBody), not a bar that owns a band of the screen.
      body: _ConversationView(
        chatId: canonicalId,
        messages: messages,
        canSend: canSend,
        composer: _ChatBottomBar(
          peerId: peerId,
          canonicalId: canonicalId,
          canSend: canSend,
        ),
        header: _ChatHeader(
          avatarSeed: peerId,
          label: peerLabel,
          autoDeleteLabel: autoDelete.isOn
              ? formatAutoDelete(t, autoDelete)
              : null,
          statusText: statusText,
          statusColor: isOnline ? AppColors.online : AppColors.textOnGlassDim,
          online: isOnline,
          // Tapping the identity pill goes where the shield goes — the peer's
          // fingerprint screen is the only "profile" this app has.
          onTapIdentity: pubkeyHex == null
              ? null
              : () => context.push(
                    '/person/${Uri.encodeComponent(pubkeyHex)}'
                    '?name=${Uri.encodeQueryComponent(peerLabel)}',
                  ),
          actions: [
            if (showRetry)
              _PillIconButton(
                icon: Icons.refresh,
                color: AppColors.brandPrimary,
                tooltip: t.bleRetry,
                onPressed: () async {
                  final manager = ref.read(chatSessionManagerProvider.notifier);
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
            _ShieldButton(
              session: session,
              ref: ref,
              peerLabel: peerLabel,
            ),
          ],
        ),
      ),
    );
  }

  /// Dedicated build for a group channel — a flat, presence-free variant of
  /// the peer chat. The conversation is keyed by the channel name and every
  /// send fans out as a broadcast to all members.
  Widget _buildChannel(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations t,
  ) {
    final joined = ref.watch(channelControllerProvider).containsKey(peerId);
    final messages = ref.watch(messagesControllerProvider)[peerId] ?? const [];

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: _ConversationView(
        chatId: peerId,
        messages: messages,
        canSend: joined,
        composer: _ChatBottomBar(
          peerId: peerId,
          canonicalId: peerId,
          canSend: joined,
          isChannel: true,
        ),
        header: _ChatHeader(
          avatarSeed: peerId,
          label: peerLabel,
          statusText: t.channelSubtitle,
          statusColor: AppColors.textOnGlassDim,
          online: false,
          actions: [
            if (joined)
              _PillIconButton(
                icon: Icons.person_add_alt_1_outlined,
                color: AppColors.brandPrimary,
                tooltip: t.channelInviteTitle,
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  backgroundColor: AppColors.bgTop,
                  isScrollControlled: true,
                  shape: const RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(22)),
                  ),
                  builder: (_) => _ChannelInviteSheet(channelName: peerId),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Peer picker for channel invitations. Each selected peer is handed the
/// channel key over their own 1:1 encrypted link, so there is no group
/// membership list to maintain — holding the key *is* membership.
class _ChannelInviteSheet extends ConsumerStatefulWidget {
  const _ChannelInviteSheet({required this.channelName});

  final String channelName;

  @override
  ConsumerState<_ChannelInviteSheet> createState() =>
      _ChannelInviteSheetState();
}

class _ChannelInviteSheetState extends ConsumerState<_ChannelInviteSheet> {
  final _selected = <String>{};
  bool _sending = false;

  Future<void> _invite() async {
    if (_selected.isEmpty || _sending) return;
    setState(() => _sending = true);

    // Grab everything context-bound before the first await — the sheet is
    // popped below, which invalidates its own context.
    final t = AppLocalizations.of(context);
    final navigator = Navigator.of(context);
    final messaging = ref.read(messagingServiceProvider);

    var delivered = 0;
    for (final pubkeyHex in _selected) {
      try {
        final fanout = await messaging.sendChannelInvite(
          channelName: widget.channelName,
          peerCanonicalId: pubkeyHex,
        );
        if (fanout > 0) delivered++;
      } catch (_) {
        // Per-peer failure is already logged; the summary below is what the
        // user acts on.
      }
    }

    if (!mounted) return;
    // Shown before the pop, but into the root overlay, so it outlives this
    // sheet rather than being disposed along with it.
    showGlassToast(
      context,
      delivered > 0 ? t.channelInviteSent : t.channelInviteNoneSent,
      icon: delivered > 0 ? Icons.send_rounded : null,
      tone: delivered > 0 ? ToastTone.success : ToastTone.danger,
    );
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final peers = ref.watch(knownPeersControllerProvider).values.toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 16),
          Text(
            t.channelInviteTitle,
            style:
                AppTypography.heading(size: 16, color: AppColors.textOnGlass),
          ),
          const SizedBox(height: 2),
          Text(
            widget.channelName,
            style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
          ),
          const SizedBox(height: 12),
          if (peers.isEmpty)
            Padding(
              padding: const EdgeInsets.all(28),
              child: Text(
                t.channelInviteEmpty,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: peers.length,
                itemBuilder: (_, i) {
                  final p = peers[i];
                  final name = p.displayName.isNotEmpty
                      ? p.displayName
                      : 'Peer ${p.pubkeyHex.substring(0, 6)}';
                  return CheckboxListTile(
                    value: _selected.contains(p.pubkeyHex),
                    activeColor: AppColors.brandPrimary,
                    controlAffinity: ListTileControlAffinity.trailing,
                    onChanged: _sending
                        ? null
                        : (v) => setState(() {
                              if (v ?? false) {
                                _selected.add(p.pubkeyHex);
                              } else {
                                _selected.remove(p.pubkeyHex);
                              }
                            }),
                    secondary: IdentityAvatar(
                      seed: p.pubkeyHex,
                      label: name,
                      size: 36,
                    ),
                    title: Text(
                      name,
                      style:
                          TextStyle(color: AppColors.textOnGlass, fontSize: 14),
                    ),
                    subtitle: p.isVerified
                        ? Text(
                            t.bleVerified,
                            style: const TextStyle(
                              color: AppColors.brandPrimary,
                              fontSize: 11,
                            ),
                          )
                        : null,
                  );
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.brandPrimary,
                  foregroundColor: Colors.black,
                ),
                onPressed: _selected.isEmpty || _sending ? null : _invite,
                child: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : Text(t.channelInviteAction),
              ),
            ),
          ),
        ],
      ),
    );
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
            Colors.white.withValues(alpha: 0.18),
            Colors.white.withValues(alpha: 0.10),
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
    required this.avatarSeed,
    required this.label,
    required this.statusText,
    this.autoDeleteLabel,
    required this.statusColor,
    required this.online,
    required this.actions,
    this.onTapIdentity,
  });

  final String avatarSeed;
  final String label;

  /// Message lifetime for this conversation when one is set, so the header can
  /// carry a timer next to the name. Null when messages are kept.
  final String? autoDeleteLabel;
  final String statusText;
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
      child: _HeaderPill(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          children: [
            _HeaderActionCircle(
              child: _PillIconButton(
                icon: Icons.arrow_back_rounded,
                color: AppColors.textOnGlass,
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: () => Navigator.of(context).maybePop(),
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
                          children: [
                            Row(
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
                              ],
                            ),
                            Text(
                              statusText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: statusColor,
                                fontSize: 11.5,
                              ),
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

/// The message in [messages] carrying [wireId], or null when it isn't there (or
/// nothing is pinned).
Message? _messageByWireId(List<Message> messages, String? wireId) {
  if (wireId == null) return null;
  for (final m in messages) {
    if (m.wireId == wireId) return m;
  }
  return null;
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
  final bool canSend;
  final Widget composer;

  @override
  ConsumerState<_ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends ConsumerState<_ConversationView> {
  final _scroll = ScrollController();

  /// Attached to the pinned message's bubble (and only to that one) so a jump
  /// can finish with [Scrollable.ensureVisible] once it is actually built.
  final _pinnedKey = GlobalKey();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Scroll the conversation to the message the pinned bar names.
  ///
  /// Bubble heights vary (one-liners, photos, quoted replies), so there is no
  /// offset to compute directly. Jump to the proportional estimate first, which
  /// lands within a screen or two, then let `ensureVisible` finish the job once
  /// the target has been built. If it never builds — the estimate was too far
  /// off — the user is at least in the right region of the history.
  Future<void> _jumpTo(String wireId) async {
    final messages = widget.messages;
    final index = messages.indexWhere((m) => m.wireId == wireId);
    if (index < 0) {
      final t = AppLocalizations.of(context);
      showGlassToast(context, t.chatPinnedGone);
      return;
    }
    if (_scroll.hasClients && messages.length > 1) {
      // The list is reversed: offset 0 is the newest message.
      final fromNewest = messages.length - 1 - index;
      final max = _scroll.position.maxScrollExtent;
      final estimate = max * (fromNewest / (messages.length - 1));
      _scroll.jumpTo(estimate.clamp(0.0, max));
    }
    for (var attempt = 0; attempt < 3; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 32));
      if (!mounted) return;
      // The bubble's own context, not this widget's: it can be scrolled out of
      // the cache and disposed between attempts, so `mounted` on the State says
      // nothing about it.
      final ctx = _pinnedKey.currentContext;
      if (ctx == null || !ctx.mounted) continue;
      await Scrollable.ensureVisible(
        ctx,
        alignment: 0.35,
        duration: const Duration(milliseconds: 220),
      );
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.messages;
    final pin = ref.watch(pinnedControllerProvider)[widget.chatId];
    // A pin whose message isn't in this chat any more (deleted, or history
    // cleared) has nothing to show or scroll to — hide the bar rather than
    // render an empty one.
    final pinnedMessage = _messageByWireId(messages, pin?.wireId);

    return _FloatingComposerBody(
      listBuilder: (padding) => messages.isEmpty
          ? _EmptyConversationState(canSend: widget.canSend)
          : ListView.builder(
              reverse: true,
              controller: _scroll,
              padding: padding,
              itemCount: messages.length,
              itemBuilder: (_, i) {
                final m = messages[messages.length - 1 - i];
                final bubble = MessageBubble(message: m, chatId: widget.chatId);
                if (pinnedMessage == null || m.id != pinnedMessage.id) {
                  return bubble;
                }
                return KeyedSubtree(key: _pinnedKey, child: bubble);
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
          widget.header,
          if (pinnedMessage != null)
            _PinnedBar(
              message: pinnedMessage,
              onTap: () => _jumpTo(pinnedMessage.wireId!),
              // Unpinning clears the banner for everyone in the chat, not just
              // here, and the button sits next to one you tap to jump — easy to
              // hit by accident, impossible to undo without finding the message
              // again.
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
        ],
      ),
    );
  }
}

/// The pinned-message island under the header. Tapping it jumps to that
/// message; the button on the right clears the pin for both sides.
///
/// Built as its own floating pane rather than a strip welded under the app bar,
/// so it belongs to the same family as the header pills, the bubbles and the
/// nav bar. The marker rail on the left and the media thumbnail are what make it
/// legible at a glance: with a photo pinned, the picture *is* the label.
class _PinnedBar extends StatelessWidget {
  const _PinnedBar({
    required this.message,
    required this.onTap,
    required this.onUnpin,
  });

  final Message message;
  final VoidCallback onTap;
  final VoidCallback onUnpin;

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
        preview = _looksLikeMime(caption) ? '📷 Photo' : caption;
      case MessageKind.audio:
        preview = '🎤 Voice message';
      case MessageKind.file:
        preview = '📎 ${message.fileName ?? 'File'}';
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
              // Telegram's pin rail: one segment per pinned message. We keep a
              // single pin per chat, so it reads as one solid marker.
              Container(
                width: 2.5,
                height: _thumb,
                decoration: BoxDecoration(
                  color: AppColors.brandPrimary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              if (thumb != null) ...[thumb, const SizedBox(width: 10)],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.chatPinnedTitle,
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
  });

  /// Builds the conversation, given the padding that keeps it clear of the two
  /// floating islands.
  final Widget Function(EdgeInsets padding) listBuilder;
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
          child: KeyedSubtree(key: _headerKey, child: widget.header),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: KeyedSubtree(key: _composerKey, child: widget.composer),
        ),
      ],
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

  /// Acknowledge the peer's messages as read now that the user is looking at
  /// them. No-op for channels (no per-recipient read state).
  void _maybeSendReadReceipts() {
    if (widget.isChannel || !mounted) return;
    ref.read(messagingServiceProvider).sendReadReceipts(widget.canonicalId);
  }

  /// Advance this chat's local read marker so its unread badge clears on the
  /// main Chats list. Applies to channels too (unlike the peer-only receipts).
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

  Future<void> _onRecordStop() async {
    final wasLocked = _recordLocked;
    final result = await ref.read(voiceRecorderProvider.notifier).stop();
    _stopTicker();
    if (mounted) setState(() => _recordLocked = false);
    if (result == null) return;
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

  /// Read the file and put it on the wire. [path] is whatever survived
  /// trimming — the trimmer falls back to the original recording, so this is
  /// never handed a missing file because a cut failed.
  Future<void> _sendVoice({
    required String path,
    required int durationMs,
  }) async {
    try {
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
      showGlassToast(context, '$e', tone: ToastTone.danger);
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
    final result = await showModalBottomSheet<MediaPickerResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bgTop,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => const MediaPickerSheet(),
    );
    if (result == null || !mounted) return;

    switch (result) {
      case MediaPickerFile():
        await _pickAndSendFile();
      case MediaPickerCamera():
        await _captureEditAndSend();
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
      await ref.read(messagingServiceProvider).sendFile(
            widget.canonicalId,
            file: File(path),
            fileName: picked!.files.single.name,
          );
    } on FileTooLarge catch (e) {
      // The two ceilings are far apart, and which one was hit changes the
      // advice: over the relay the same file may well go once they are in
      // Bluetooth range.
      if (mounted) {
        showGlassToast(
          context,
          e.relayOnly ? t.fileTooLargeRelay : t.fileTooLargeMesh,
          tone: ToastTone.danger,
        );
      }
    } catch (e) {
      if (mounted) {
        showGlassToast(context, '$e', tone: ToastTone.danger);
      }
    }
  }

  /// Gallery pick → preview with a caption → send.
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
      MaterialPageRoute<MediaPreviewResult>(
        builder: (_) => MediaPreviewScreen(items: loaded),
      ),
    );
    if (result == null || !mounted) return;

    for (var i = 0; i < result.bytes.length; i++) {
      // The caption belongs to the set, not to each photo — repeating it under
      // every picture in a batch would read as a stutter. It goes on the first.
      await _encodeAndSend(
        result.bytes[i],
        '${assets[i].id}-${DateTime.now().microsecondsSinceEpoch}',
        caption: i == 0 ? result.caption : null,
      );
      if (!mounted) return;
    }
  }

  /// Camera tile → in-app capture → editor → send.
  Future<void> _captureEditAndSend() async {
    final captured = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute<Uint8List>(
        builder: (_) => const CameraCaptureScreen(),
      ),
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
  }) async {
    try {
      final wire = await encodeBytesForMesh(bytes);
      if (!mounted) return;
      if (wire == null) {
        showGlassToast(context, 'Image too large to send',
            tone: ToastTone.danger);
        return;
      }
      await _sendImageBytes(wire, idHint, caption: caption);
    } catch (e) {
      if (!mounted) return;
      showGlassToast(context, '$e', tone: ToastTone.danger);
    }
  }

  /// Cache the outgoing bytes (so our own bubble renders at once) and hand them
  /// to the transport.
  Future<void> _sendImageBytes(
    Uint8List bytes,
    String idHint, {
    String? caption,
  }) async {
    final messaging = ref.read(messagingServiceProvider);
    final cachedPath = await _cacheOutgoingImage(bytes, idHint);
    await messaging.sendImage(
      widget.peerId,
      bytes: bytes,
      mime: 'image/jpeg',
      cachedPath: cachedPath,
      caption: caption,
    );
  }

  /// Persist the downscaled bytes we're about to send to the app cache, so the
  /// sender's own bubble can render the image immediately (the picker gives us
  /// bytes, not a stable file path).
  Future<String?> _cacheOutgoingImage(Uint8List bytes, String assetId) async {
    try {
      final dir = Directory(
        '${(await getApplicationCacheDirectory()).path}/cubechat/sent',
      );
      if (!await dir.exists()) await dir.create(recursive: true);
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
    // A new inbound message while the chat is open should be acknowledged and
    // counted as read (so its badge never appears on the list behind us).
    ref.listen(messagesControllerProvider, (_, __) {
      _markChatRead();
      _maybeSendReadReceipts();
    });
    // Media (images / voice) is 1:1 only for now — channels broadcast text.
    final mediaEnabled = widget.canSend && !widget.isChannel;

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
          mediaEnabled && !voiceState.isRecording ? _pickAndSendImage : null,
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
          if (widget.isChannel) {
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

    if (activeReply == null) return composer;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReplyComposeBar(
          target: activeReply,
          onCancel: () =>
              ref.read(messageReplyTargetProvider.notifier).state = null,
        ),
        composer,
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

/// Shield icon in the chat header that opens the verification screen.
///
/// Three visual states:
///   - dimmed shield_outlined: handshake not yet complete (peer pubkey unknown)
///   - white shield_outlined:  handshake complete, peer not yet verified
///   - brand-green verified:   user has compared fingerprints and confirmed
class _ShieldButton extends StatelessWidget {
  const _ShieldButton({
    required this.session,
    required this.ref,
    required this.peerLabel,
  });

  final ChatSession? session;
  final WidgetRef ref;
  final String peerLabel;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final pubkeyHex = session?.remotePubkeyHex;
    final known = ref.watch(knownPeersControllerProvider);
    final entry = pubkeyHex == null ? null : known[pubkeyHex];
    final isVerified = entry?.isVerified ?? false;
    final rotated = entry?.hasUnacknowledgedRotation ?? false;
    final canVerify = pubkeyHex != null;

    final IconData icon = rotated
        ? Icons.gpp_maybe_outlined
        : (isVerified ? Icons.verified : Icons.shield_outlined);
    final Color color = rotated
        ? AppColors.danger
        : (isVerified
            ? AppColors.brandPrimary
            : (canVerify ? AppColors.textOnGlass : AppColors.textOnGlassFaint));

    return _PillIconButton(
      icon: icon,
      color: color,
      tooltip: rotated ? t.peerKeyRotated : t.verifyTitle,
      onPressed: !canVerify
          ? null
          : () => context.push(
                '/person/${Uri.encodeComponent(pubkeyHex)}'
                '?name=${Uri.encodeQueryComponent(peerLabel)}',
              ),
    );
  }
}
