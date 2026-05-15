import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/transport/chat_session.dart';
import '../../../core/transport/chat_session_manager.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../l10n/app_localizations.dart';
import '../data/messages_controller.dart';
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
    final messages = messagesMap[peerId] ?? const [];
    final session = ref.watch(chatSessionManagerProvider)[peerId];
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
          IconButton(
            icon: Icon(Icons.shield_outlined, color: AppColors.textOnGlass),
            onPressed: () => _showFingerprint(context, session, t),
            tooltip: t.profileFingerprint,
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
              onSend: canSend
                  ? (text) async {
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
                    }
                  : (_) {},
            ),
          ],
        ),
      ),
    );
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

  Future<void> _showFingerprint(
    BuildContext context,
    ChatSession? session,
    AppLocalizations t,
  ) async {
    final fp = await session?.remoteFingerprint();
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgTop,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
        ),
        title: Text(
          t.profileFingerprint,
          style: TextStyle(color: AppColors.textOnGlass, fontSize: 16, fontWeight: FontWeight.w600),
        ),
        content: Text(
          fp ?? t.chatSessionFingerprintPending,
          style: AppTypography.mono(size: 12.5, color: AppColors.textOnGlass),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('OK', style: TextStyle(color: AppColors.brandPrimary)),
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
