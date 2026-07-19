import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../../core/notifications/notification_service.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/transport/chat_session.dart';
import '../../../core/transport/chat_session_manager.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/transport/mtu_budget.dart';
import '../../../core/util/app_lifecycle.dart';
import '../../../core/utils/time_format.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../l10n/app_localizations.dart';
import '../../channels/data/channel_controller.dart';
import '../../chats/data/read_markers_controller.dart';
import '../../peers/data/known_peers_controller.dart';
import '../../peers/data/peer_discovery_controller.dart';
import '../data/message_edit_target.dart';
import '../data/message_reply_target.dart';
import '../data/messages_controller.dart';
import '../data/voice_recorder_controller.dart';
import '../domain/command_processor.dart';
import 'widgets/chat_input.dart';
import 'widgets/media_picker_sheet.dart';
import 'widgets/message_bubble.dart';
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
    final canSend = session?.isEstablished ?? false;

    // Offer a reconnect whenever there's no live session to speak over — the
    // old condition only covered a session that reached `failed`, but a GATT
    // connect that times out never creates one, leaving the screen stuck on
    // "waiting for the handshake" with no way out. Only meaningful when we
    // routed here with a device id: a chat opened from the Chats list carries
    // a pubkey-hex, and you cannot open a GATT link to a public key.
    final showRetry = _isBleDeviceId(peerId) &&
        (session == null || session.status == ChatSessionStatus.failed);

    // Presence. An established Noise session is a definite "connected right
    // now". Otherwise we fall back to the last mesh announcement: peers
    // re-announce every 60s, so a 150s window (~2.5 ticks) absorbs a single
    // missed beacon without flickering offline.
    final known = ref.watch(knownPeersControllerProvider)[canonicalId];
    final lastSeen = known?.lastSeen;
    final isOnline = (session?.isEstablished ?? false) ||
        (lastSeen != null &&
            DateTime.now().difference(lastSeen) < const Duration(seconds: 150));
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

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: BackButton(color: AppColors.textOnGlass),
        title: Row(
          children: [
            IdentityAvatar(
              seed: peerId,
              label: peerLabel,
              size: 36,
              online: isOnline,
              heroTag: 'avatar-$peerId',
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    peerLabel,
                    style: AppTypography.heading(
                        size: 16, color: AppColors.textOnGlass),
                  ),
                  Text(
                    statusText,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isOnline
                          ? AppColors.online
                          : AppColors.textOnGlassDim,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (showRetry)
            IconButton(
              icon: Icon(Icons.refresh, color: AppColors.brandPrimary),
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
      body: SafeArea(
        top: false,
        child: _FloatingComposerBody(
          listBuilder: (padding) => messages.isEmpty
              ? _EmptyConversationState(canSend: canSend)
              : ListView.builder(
                  reverse: true,
                  padding: padding,
                  itemCount: messages.length,
                  itemBuilder: (_, i) {
                    final m = messages[messages.length - 1 - i];
                    return MessageBubble(message: m, chatId: canonicalId);
                  },
                ),
          composer: _ChatBottomBar(
            peerId: peerId,
            canonicalId: canonicalId,
            canSend: canSend,
          ),
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
      appBar: AppBar(
        leading: BackButton(color: AppColors.textOnGlass),
        title: Row(
          children: [
            IdentityAvatar(
              seed: peerId,
              label: peerLabel,
              size: 36,
              online: false,
              heroTag: 'avatar-$peerId',
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    peerLabel,
                    style: AppTypography.heading(
                        size: 16, color: AppColors.textOnGlass),
                  ),
                  Text(
                    t.channelSubtitle,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textOnGlassDim,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (joined)
            IconButton(
              icon: Icon(Icons.person_add_alt_1_outlined,
                  color: AppColors.brandPrimary),
              tooltip: t.channelInviteTitle,
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                backgroundColor: AppColors.bgTop,
                isScrollControlled: true,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
                ),
                builder: (_) => _ChannelInviteSheet(channelName: peerId),
              ),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _FloatingComposerBody(
          listBuilder: (padding) => messages.isEmpty
              ? _EmptyConversationState(canSend: joined)
              : ListView.builder(
                  reverse: true,
                  padding: padding,
                  itemCount: messages.length,
                  itemBuilder: (_, i) {
                    final m = messages[messages.length - 1 - i];
                    return MessageBubble(message: m, chatId: peerId);
                  },
                ),
          composer: _ChatBottomBar(
            peerId: peerId,
            canonicalId: peerId,
            canSend: joined,
            isChannel: true,
          ),
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
  });

  /// Builds the conversation, given the padding that keeps it clear of the
  /// composer.
  final Widget Function(EdgeInsets padding) listBuilder;
  final Widget composer;

  @override
  State<_FloatingComposerBody> createState() => _FloatingComposerBodyState();
}

class _FloatingComposerBodyState extends State<_FloatingComposerBody> {
  final _composerKey = GlobalKey();

  /// Height used until the first real measurement lands — a single-line
  /// composer. Only ever wrong for one frame.
  static const double _initialGuess = 76;

  /// Breathing room between the newest message and the composer above it.
  static const double _clearance = 12;

  double _composerHeight = _initialGuess;

  void _measure(Duration _) {
    final box = _composerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final h = box.size.height;
    // Sub-pixel churn would otherwise setState on every frame.
    if ((h - _composerHeight).abs() < 0.5) return;
    setState(() => _composerHeight = h);
  }

  @override
  Widget build(BuildContext context) {
    // Re-measured after each build because the composer changes height while
    // the user types. The guard above makes the steady state a no-op.
    WidgetsBinding.instance.addPostFrameCallback(_measure);

    return Stack(
      children: [
        // reverse: true means the list starts at the visual bottom, so this
        // bottom padding is what the newest message clears itself by.
        widget.listBuilder(
          EdgeInsets.only(
            top: _clearance,
            bottom: _composerHeight + _clearance,
          ),
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
    final result = await ref.read(voiceRecorderProvider.notifier).stop();
    _stopTicker();
    if (result == null) return;
    if (!widget.canSend) return;
    try {
      final bytes = await File(result.path).readAsBytes();
      await ref.read(messagingServiceProvider).sendAudio(
            widget.peerId,
            bytes: bytes,
            mime: 'audio/aac',
            durationMs: result.durationMs,
            cachedPath: result.path,
          );
    } catch (e) {
      if (!mounted) return;
      showGlassToast(context, '$e', tone: ToastTone.danger);
    }
  }

  Future<void> _onRecordCancel() async {
    await ref.read(voiceRecorderProvider.notifier).cancel();
    _stopTicker();
  }

  Future<void> _pickAndSendImage() async {
    // Custom in-app gallery picker (multi-select) instead of the one-shot
    // system picker, so several photos go out in one action.
    final assets = await showModalBottomSheet<List<AssetEntity>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bgTop,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => const MediaPickerSheet(),
    );
    if (assets == null || assets.isEmpty || !mounted) return;

    final messaging = ref.read(messagingServiceProvider);
    for (final asset in assets) {
      try {
        final bytes = await _encodeForMesh(asset);
        if (bytes == null) continue;
        final cachedPath = await _cacheOutgoingImage(bytes, asset.id);
        await messaging.sendImage(
          widget.peerId,
          bytes: bytes,
          mime: 'image/jpeg',
          cachedPath: cachedPath,
        );
      } catch (e) {
        if (!mounted) return;
        showGlassToast(context, '$e', tone: ToastTone.danger);
      }
    }
  }

  /// Re-encode a picked photo down to something the BLE mesh can actually
  /// carry — at most [kMaxOutgoingImageBytes].
  ///
  /// A fixed 1280 px / q72 (what this used to do) still produced ~1 MB for a
  /// detailed photo, which is 10912 chunks against a 8192 cap: the transport
  /// threw and the user just saw "image too large". Pixel dimensions don't
  /// predict JPEG size — detail does — so step down the rungs until the bytes
  /// come in under budget, and send the smallest rung if even that overshoots
  /// (a 320 px thumbnail beats a failed send).
  Future<Uint8List?> _encodeForMesh(AssetEntity asset) async {
    const rungs = <({int size, int quality})>[
      (size: 1280, quality: 70),
      (size: 1024, quality: 65),
      (size: 800, quality: 60),
      (size: 640, quality: 55),
      (size: 480, quality: 50),
      (size: 320, quality: 45),
    ];
    Uint8List? smallest;
    for (final rung in rungs) {
      final bytes = await asset.thumbnailDataWithSize(
        ThumbnailSize(rung.size, rung.size),
        quality: rung.quality,
      );
      if (bytes == null) continue;
      smallest = bytes;
      if (bytes.length <= kMaxOutgoingImageBytes) return bytes;
    }
    return smallest;
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
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        border: Border(
          left: BorderSide(color: AppColors.brandPrimary, width: 3),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  header,
                  style: TextStyle(
                    color: AppColors.brandPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  target.preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textOnGlassDim,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: AppColors.textOnGlassDim,
            onPressed: onCancel,
            tooltip: t.cancel,
          ),
        ],
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

    return IconButton(
      icon: Icon(icon, color: color),
      tooltip: rotated ? t.peerKeyRotated : t.verifyTitle,
      onPressed: !canVerify
          ? null
          : () => context.push(
                '/verify/${Uri.encodeComponent(pubkeyHex)}'
                '?name=${Uri.encodeQueryComponent(peerLabel)}',
              ),
    );
  }
}
