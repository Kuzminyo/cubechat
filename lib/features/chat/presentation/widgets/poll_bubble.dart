import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/transport/messaging_service.dart';
import '../../../../l10n/app_localizations.dart';
import '../../models/message.dart';

class PollBubble extends ConsumerWidget {
  const PollBubble({
    super.key,
    required this.message,
    required this.chatId,
  });

  final Message message;
  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final total = message.pollVotes.length;
    final selected = message.pollVotes['me'];
    final counts = List<int>.filled(message.pollOptions.length, 0);
    for (final option in message.pollVotes.values) {
      if (option >= 0 && option < counts.length) counts[option]++;
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 220),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.poll_outlined,
                  size: 16, color: AppColors.brandPrimary),
              const SizedBox(width: 6),
              Text(
                t.channelPollTitle,
                style: TextStyle(
                  color: AppColors.brandPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            message.text,
            style: TextStyle(
              color: AppColors.textOnGlass,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          for (var index = 0; index < message.pollOptions.length; index++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: message.wireId == null
                    ? null
                    : () => ref
                        .read(messagingServiceProvider)
                        .sendChannelPollVote(chatId, message.wireId!, index),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: total == 0 ? 0 : counts[index] / total,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color:
                                AppColors.brandPrimary.withValues(alpha: .16),
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: selected == index
                              ? AppColors.brandPrimary
                              : Colors.white.withValues(alpha: .12),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            selected == index
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_off_rounded,
                            size: 17,
                            color: selected == index
                                ? AppColors.brandPrimary
                                : AppColors.textOnGlassDim,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              message.pollOptions[index],
                              style: TextStyle(
                                color: AppColors.textOnGlass,
                                fontSize: 13.5,
                              ),
                            ),
                          ),
                          Text(
                            total == 0
                                ? '0%'
                                : '${(counts[index] * 100 / total).round()}%',
                            style: TextStyle(
                              color: AppColors.textOnGlassDim,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Text(
            t.channelPollVotes(total),
            style: TextStyle(
              color: AppColors.textOnGlassDim,
              fontSize: 11.5,
            ),
          ),
        ],
      ),
    );
  }
}
