import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../l10n/app_localizations.dart';
import '../../chats/models/chat.dart';
import '../data/mock_messages.dart';
import '../models/message.dart';
import 'widgets/chat_input.dart';
import 'widgets/message_bubble.dart';

final _messagesProvider =
    StateProvider.family<List<Message>, String>((_, chatId) => mockMessages(chatId));

class ChatScreen extends ConsumerWidget {
  const ChatScreen({super.key, required this.chat});

  final Chat chat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final messages = ref.watch(_messagesProvider(chat.id));

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: BackButton(color: AppColors.textOnGlass),
        title: Row(
          children: [
            IdentityAvatar(
              seed: chat.peerId,
              label: chat.peerName,
              size: 36,
              online: chat.isOnline,
              heroTag: 'avatar-${chat.peerId}',
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    chat.peerName,
                    style: AppTypography.heading(size: 16, color: AppColors.textOnGlass),
                  ),
                  Text(
                    chat.isOnline ? t.profileTransportMesh : t.chatEncryptedNotice,
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
          IconButton(
            icon: Icon(Icons.shield_outlined, color: AppColors.textOnGlass),
            onPressed: () {},
            tooltip: t.profileFingerprint,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
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
              onSend: (text) {
                final next = List<Message>.from(messages)
                  ..add(
                    Message(
                      id: 'm${DateTime.now().microsecondsSinceEpoch}',
                      chatId: chat.id,
                      text: text,
                      sentAt: DateTime.now(),
                      isMine: true,
                      status: MessageStatus.sending,
                    ),
                  );
                ref.read(_messagesProvider(chat.id).notifier).state = next;
              },
            ),
          ],
        ),
      ),
    );
  }
}
