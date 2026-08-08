import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/utils/time_format.dart';
import '../../../../core/widgets/unread_badge.dart';
import '../../../peers/presentation/widgets/peer_avatar.dart';
import '../../../../l10n/app_localizations.dart';
import '../../models/chat.dart';

/// The contents of one chat row: avatar, name + status, and last-message
/// preview. It paints no surface of its own — the [FloatingGlass] island the
/// list wraps it in owns the background, tap ripple and long-press.
class ChatTile extends StatelessWidget {
  const ChatTile({super.key, required this.chat});

  final Chat chat;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    // Unread chats "light up": a heavier name and a brighter, non-dimmed
    // preview line, on top of the count badge — so a glance down the list lands
    // on the conversations with something new.
    final unread = chat.unreadCount > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          // No hero tag, so opening a chat is just the page sliding in.
          //
          // The avatar used to fly from this row up into the chat header, which
          // is the "jumping" a tester asked to be rid of: the page arrives from
          // the right while one element takes a different path across the
          // screen, and the two motions argue with each other.
          //
          // A hero also has to hide its source for the length of the flight and
          // put it back afterwards, and a flight cut short — by the back
          // gesture, most of all — can leave the source hidden. That is a row
          // whose picture is simply missing until something rebuilds it, which
          // is the other half of what was reported.
          PeerAvatar(
            peerId: chat.peerId,
            label: chat.peerName,
            size: 48,
            online: chat.isOnline,
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
                          fontWeight:
                              unread ? FontWeight.w800 : FontWeight.w600,
                        ),
                      ),
                    ),
                    if (chat.isVerified) ...[
                      const SizedBox(width: 4),
                      Icon(
                        Icons.verified,
                        color: AppColors.brandPrimary,
                        size: 14,
                      ),
                    ],
                    if (chat.isChannel) ...[
                      const SizedBox(width: 6),
                      _StatusPill(
                        icon: Icons.campaign_rounded,
                        label: t.chatsStatusChannel,
                      ),
                    ] else if (chat.signKeyRotated) ...[
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
                    ],
                    // No "offline" pill. The dot on the avatar already says
                    // who is here, and its absence says the rest — spelling it
                    // out put a grey badge on almost every row, which is a lot
                    // of ink for the state a list is usually in.
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  chat.isDraft
                      ? '${t.chatDraft}: ${chat.lastMessage}'
                      : chat.lastMessage,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: chat.isDraft
                        ? AppColors.brandPrimary
                        : unread
                            ? AppColors.textOnGlass
                            : AppColors.textOnGlassDim,
                    fontSize: 13,
                    height: 1.3,
                    fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
          // Time and unread count as their own column, not trailing the name.
          // Inside the name row their position moved with whatever preceded
          // them — a long name or an extra pill — so the timestamps came out
          // ragged down the list instead of forming a column.
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                formatChatListTime(context, chat.lastTime),
                style: TextStyle(
                  color: AppColors.textOnGlassFaint,
                  fontSize: 11,
                ),
              ),
              // The star sits here, under the timestamp, rather than beside the
              // name. Next to the name it was one more thing pushing the name
              // around in a row that already carries a verified tick and a
              // transport pill — and a favourite is a property of the row, not
              // of the name. Small, and in the corner: it marks, it does not
              // announce. Sharing a line with the badge keeps every row the
              // same height whether or not either is there.
              if (chat.unreadCount > 0 || chat.isFavorite) ...[
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (chat.isFavorite)
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Icon(Icons.star_rounded,
                            color: AppColors.warning, size: 13),
                      ),
                    if (chat.unreadCount > 0)
                      UnreadBadge(count: chat.unreadCount),
                  ],
                ),
              ],
            ],
          ),
        ],
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
