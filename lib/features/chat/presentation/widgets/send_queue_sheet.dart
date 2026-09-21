import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/identity/anon_name.dart';
import '../../../../core/theme/colors.dart';
import '../../../../core/theme/typography.dart';
import '../../../../core/transport/messaging_service.dart';
import '../../../../core/widgets/floating_glass.dart';
import '../../../../core/widgets/glass_sheet.dart';
import '../../../../core/widgets/glass_toast.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../peers/data/contact_aliases_controller.dart';
import '../../../peers/data/known_peers_controller.dart';
import '../../data/send_queue.dart';
import '../../domain/message_preview.dart';

/// "N messages waiting for a connection", above the chat list — only while
/// there are any.
///
/// The queue existed and did its job silently: a message that found no road
/// was held and went when one opened. What nobody could see was that anything
/// was waiting at all, short of opening each conversation and reading the
/// clocks. Asked for as "always visible whether a message is still waiting for
/// a connection or already delivered".
class SendQueueEntry extends ConsumerWidget {
  const SendQueueEntry({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(sendQueueProvider.select((q) => q.length));
    if (count == 0) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: FloatingGlass(
        blur: false,
        borderRadius: 18,
        onTap: () => showSendQueueSheet(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 20,
                color: AppColors.textOnGlassDim,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  t.sendQueueCount(count),
                  style: AppTypography.rowTitle,
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: AppColors.textOnGlassFaint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What is waiting, for whom, and the two things a person can do about it:
/// push it along now, or take one back before it leaves.
Future<void> showSendQueueSheet(BuildContext context) =>
    showGlassSheet<void>(
      context: context,
      builder: (_) => const _SendQueueSheet(),
    );

class _SendQueueSheet extends ConsumerWidget {
  const _SendQueueSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final queue = ref.watch(sendQueueProvider);
    final peers = ref.watch(knownPeersControllerProvider);
    final aliases = ref.watch(contactAliasesControllerProvider);
    final time = DateFormat.Hm(Localizations.localeOf(context).toString());

    String nameOf(String chatId) {
      if (chatId.startsWith('#')) return chatId;
      final peer = peers[chatId];
      return contactDisplayName(
        alias: aliases[chatId],
        rawBroadcastName: peer?.displayName ?? '',
        pubkeyHex: chatId,
      );
    }

    // Empty once the last one went or was cancelled: the sheet has nothing
    // left to say, so it closes rather than sitting open over nothing.
    if (queue.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.of(context).maybePop();
      });
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.sendQueueTitle,
              style: AppTypography.heading(
                size: 18,
                color: AppColors.textOnGlass,
              ),
            ),
            const SizedBox(height: 6),
            Text(t.sendQueueHint, style: AppTypography.supporting),
            const SizedBox(height: 12),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final item in queue)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Icon(
                            Icons.cloud_off_rounded,
                            size: 18,
                            color: AppColors.textOnGlassFaint,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  nameOf(item.chatId),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.rowTitle,
                                ),
                                Text(
                                  '${time.format(item.message.sentAt)} · '
                                  '${messagePreview(item.message, t)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.supporting,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: t.sendQueueCancel,
                            icon: Icon(
                              Icons.close_rounded,
                              color: AppColors.textOnGlassDim,
                            ),
                            onPressed: () {
                              final taken = ref
                                  .read(messagingServiceProvider)
                                  .cancelQueued(
                                    chatId: item.chatId,
                                    message: item.message,
                                  );
                              showGlassToast(
                                context,
                                taken ? t.sendQueueCancelled : t.sendQueueTooLate,
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.refresh_rounded),
                label: Text(t.sendQueueRetry),
                onPressed: () =>
                    ref.read(messagingServiceProvider).retryQueuedNow(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
