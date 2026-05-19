import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/utils/time_format.dart';
import '../../../../core/widgets/identity_avatar.dart';
import '../../../../core/widgets/unread_badge.dart';
import '../../../../l10n/app_localizations.dart';
import '../../models/chat.dart';

class ChatTile extends StatelessWidget {
  const ChatTile({super.key, required this.chat, required this.onTap});

  final Chat chat;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              IdentityAvatar(
                seed: chat.peerId,
                label: chat.peerName,
                size: 48,
                online: chat.isOnline,
                heroTag: 'avatar-${chat.peerId}',
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            chat.peerName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textOnGlass,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (chat.isVerified) ...[
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.verified,
                            color: AppColors.brandPrimary,
                            size: 14,
                          ),
                        ],
                        if (chat.isReachableViaMesh) ...[
                          const SizedBox(width: 6),
                          _StatusPill(
                            icon: Icons.hub_outlined,
                            label: t.chatsStatusViaMesh,
                          ),
                        ] else if (!chat.isOnline) ...[
                          const SizedBox(width: 6),
                          _StatusPill(
                            icon: Icons.cloud_off_outlined,
                            label: t.chatsStatusOffline,
                            muted: true,
                          ),
                        ],
                        const Spacer(),
                        Text(
                          formatChatListTime(context, chat.lastTime),
                          style: TextStyle(
                            color: AppColors.textOnGlassFaint,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            chat.lastMessage,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textOnGlassDim,
                              fontSize: 13,
                              height: 1.3,
                            ),
                          ),
                        ),
                        if (chat.unreadCount > 0) ...[
                          const SizedBox(width: 8),
                          UnreadBadge(count: chat.unreadCount),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tiny rounded badge tucked into the chat-tile header row to indicate the
/// transport state (mesh-only reachable vs offline). Kept compact so it
/// doesn't crowd out the timestamp on narrow screens.
class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.icon,
    required this.label,
    this.muted = false,
  });

  final IconData icon;
  final String label;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final color = muted ? AppColors.textOnGlassFaint : AppColors.brandPrimary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: muted ? 0.08 : 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}
