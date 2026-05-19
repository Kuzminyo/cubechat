import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/transport/chat_session.dart';
import '../../../core/transport/chat_session_manager.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../l10n/app_localizations.dart';
import '../../peers/data/known_peers_controller.dart';
import '../data/messages_controller.dart';
import '../domain/command_processor.dart';
import 'widgets/chat_input.dart';
import 'widgets/message_bubble.dart';

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
    final messages = messagesMap[canonicalId] ??
        messagesMap[peerId] ??
        const [];
    final canSend = session?.isEstablished ?? false;

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
              online: session != null,
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
                    style: AppTypography.heading(size: 16, color: AppColors.textOnGlass),
                  ),
                  Text(
                    _statusLabel(t, session),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: canSend ? AppColors.brandPrimary : AppColors.textOnGlassDim,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (session?.status == ChatSessionStatus.failed)
            IconButton(
              icon: Icon(Icons.refresh, color: AppColors.brandPrimary),
              tooltip: t.bleRetry,
              onPressed: () async {
                final manager = ref.read(chatSessionManagerProvider.notifier);
                manager.drop(peerId);
                try {
                  await ref.read(messagingServiceProvider).connectAsInitiator(
                        BluetoothDevice.fromId(peerId),
                        displayName: peerLabel,
                      );
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      backgroundColor: AppColors.danger.withValues(alpha: 0.85),
                      content:
                          Text('$e', style: const TextStyle(color: Colors.white)),
                    ),
                  );
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
        child: Column(
          children: [
            Expanded(
              child: messages.isEmpty
                  ? _EmptyConversationState(canSend: canSend)
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      itemCount: messages.length,
                      itemBuilder: (_, i) {
                        final m = messages[messages.length - 1 - i];
                        return MessageBubble(message: m);
                      },
                    ),
            ),
            ChatInput(
              hint: t.chatInputHint,
              sendTooltip: t.chatSend,
              onAttach: canSend ? () => _pickAndSendImage(context, ref) : null,
              // Commands always work; regular messages need an established
              // session. We let any /cmd through even when offline so the
              // user can `/nick` / `/clear` / `/wipe` without a peer.
              onSend: (text) async {
                // Try commands first.
                final result = await CommandProcessor(ref, canonicalId)
                    .tryExecute(text);
                if (result != null) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      backgroundColor: result.success
                          ? AppColors.brandPrimary.withValues(alpha: 0.85)
                          : AppColors.danger.withValues(alpha: 0.85),
                      content: Text(result.message,
                          style: const TextStyle(color: Colors.white)),
                      duration: Duration(
                        seconds: result.message.contains('\n') ? 5 : 2,
                      ),
                    ),
                  );
                  return;
                }
                // Not a command — fall through to real send.
                if (!canSend) return;
                try {
                  await ref.read(messagingServiceProvider).sendText(peerId, text);
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      backgroundColor: AppColors.danger.withValues(alpha: 0.85),
                      content: Text('$e',
                          style: const TextStyle(color: Colors.white)),
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Triggered by the paperclip button. Picks one image from the gallery,
  /// caps its size to keep BLE chunking sane, and hands off to
  /// MessagingService.sendImage. We deliberately cap dimensions in the
  /// picker rather than resizing client-side — fewer dependencies and the
  /// outbound bandwidth budget makes large transfers a bad idea anyway.
  Future<void> _pickAndSendImage(BuildContext context, WidgetRef ref) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1280,
      maxHeight: 1280,
      imageQuality: 70,
    );
    if (picked == null) return;
    try {
      final bytes = await File(picked.path).readAsBytes();
      final mime = _guessMime(picked.path);
      await ref.read(messagingServiceProvider).sendImage(
            peerId,
            bytes: bytes,
            mime: mime,
            cachedPath: picked.path,
          );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.danger.withValues(alpha: 0.85),
          content: Text('$e', style: const TextStyle(color: Colors.white)),
        ),
      );
    }
  }

  static String _guessMime(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }

  String _statusLabel(AppLocalizations t, ChatSession? session) {
    if (session == null) return t.chatEncryptedNotice;
    switch (session.status) {
      case ChatSessionStatus.idle:
      case ChatSessionStatus.handshakingInitiator:
      case ChatSessionStatus.handshakingResponder:
        return t.chatSessionHandshaking;
      case ChatSessionStatus.established:
        return t.chatSessionEstablished;
      case ChatSessionStatus.failed:
        return t.chatSessionFailed;
    }
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
              color: canSend ? AppColors.brandPrimary : AppColors.textOnGlassFaint,
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
    final canVerify = pubkeyHex != null;

    final IconData icon = isVerified ? Icons.verified : Icons.shield_outlined;
    final Color color = isVerified
        ? AppColors.brandPrimary
        : (canVerify ? AppColors.textOnGlass : AppColors.textOnGlassFaint);

    return IconButton(
      icon: Icon(icon, color: color),
      tooltip: t.verifyTitle,
      onPressed: !canVerify
          ? null
          : () => context.push(
                '/verify/${Uri.encodeComponent(pubkeyHex)}'
                '?name=${Uri.encodeQueryComponent(peerLabel)}',
              ),
    );
  }
}
