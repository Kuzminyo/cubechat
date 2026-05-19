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
                        if (chat.signKeyRotated) ...[
                          const SizedBox(width: 6),
                          _StatusPill(
                            icon: Icons.warning_amber_rounded,
                            label: t.peerKeyRotated,
                            tone: _PillTone.warning,
                          ),
                        ] else if (chat.isReachableViaMesh) ...[
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
                            tone: _PillTone.muted,
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

enum _PillTone { brand, muted, warning }

/// Tiny rounded badge tucked into the chat-tile header row to indicate the
/// transport state (mesh-only / offline / key-rotated). Kept compact so it
/// doesn't crowd out the timestamp on narrow screens.
class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.icon,
    required this.label,
    this.tone = _PillTone.brand,
  });

  final IconData icon;
  final String label;
  final _PillTone tone;

  @override
  Widget build(BuildContext context) {
    final Color color;
    final double alpha;
    switch (tone) {
      case _PillTone.brand:
        color = AppColors.brandPrimary;
        alpha = 0.14;
      case _PillTone.muted:
        color = AppColors.textOnGlassFaint;
        alpha = 0.08;
      case _PillTone.warning:
        color = AppColors.danger;
        alpha = 0.18;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: alpha),
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
