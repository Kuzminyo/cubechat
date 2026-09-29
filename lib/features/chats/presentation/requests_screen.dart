import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/data/messages_controller.dart';
import '../../peers/data/known_peers_controller.dart';
import '../data/message_requests_controller.dart';
import 'chats_list_screen.dart' show requestChatsProvider, routeForChat;
import 'widgets/chat_tile.dart';

/// Strangers' first messages, held apart until they are let in — Profile →
/// Privacy → "Request". Opening one reads it without telling the sender;
/// nothing about a request reaches them until "Accept".
class RequestsScreen extends ConsumerWidget {
  const RequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final chats = ref.watch(requestChatsProvider);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: BackButton(color: AppColors.textOnGlass),
        title: Text(
          t.requestsTitle,
          style: AppTypography.heading(size: 18, color: AppColors.textOnGlass),
        ),
      ),
      body: SafeArea(
        top: false,
        child: chats.isEmpty
            ? Center(
                child: Text(
                  t.requestsEmpty,
                  style:
                      TextStyle(color: AppColors.textOnGlassDim, fontSize: 14),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 140),
                itemCount: chats.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final chat = chats[i];
                  return FloatingGlass(
                    blur: false,
                    borderRadius: 18,
                    onTap: () => context.push(routeForChat(chat)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ChatTile(chat: chat),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                          child: RequestActions(peer: chat.peerId),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}

/// Accept, delete, block — the same three wherever a request is shown.
/// [onGone] runs after delete or block, when the chat no longer exists for
/// the person looking at it (the chat screen closes itself there).
class RequestActions extends ConsumerWidget {
  const RequestActions({super.key, required this.peer, this.onGone});

  final String peer;
  final VoidCallback? onGone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final requests = ref.read(messageRequestsProvider.notifier);
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: () async {
            await ref
                .read(messagesControllerProvider.notifier)
                .clearForChat(peer);
            await requests.drop(peer);
            onGone?.call();
          },
          child: Text(
            t.requestDelete,
            style: TextStyle(color: AppColors.textOnGlassDim),
          ),
        ),
        TextButton(
          onPressed: () async {
            await ref
                .read(knownPeersControllerProvider.notifier)
                .setBlocked(peer, true);
            await requests.drop(peer);
            onGone?.call();
          },
          child:
              Text(t.requestBlock, style: TextStyle(color: AppColors.danger)),
        ),
        FilledButton(
          onPressed: () => requests.accept(peer),
          child: Text(t.requestAccept),
        ),
      ],
    );
  }
}

/// Shown above a conversation that is still a request.
class RequestBanner extends ConsumerWidget {
  const RequestBanner({super.key, required this.peer});

  final String peer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(
      messageRequestsProvider.select((r) => r.pending.contains(peer)),
    );
    if (!pending) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final known = ref.watch(knownPeersControllerProvider)[peer]?.displayName;
    final name = known == null || known.isEmpty
        ? peer.substring(0, peer.length < 8 ? peer.length : 8)
        : known;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: FloatingGlass(
        blur: false,
        borderRadius: 18,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                t.requestBanner(name),
                style: TextStyle(
                  color: AppColors.textOnGlass,
                  fontSize: 13.5,
                  height: 1.35,
                ),
              ),
              RequestActions(
                peer: peer,
                onGone: () {
                  if (context.mounted && context.canPop()) context.pop();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
