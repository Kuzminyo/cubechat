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
  const ChatTile({
    super.key,
    required this.chat,
    this.selected = false,
    this.reorderIndex,
  });

  final Chat chat;

  /// Picked out for a bulk action — see `chatSelectionProvider`. Marked on the
  /// avatar rather than by tinting the row: the row's own colours already say
  /// whether there is something unread in it, and a second meaning on the same
  /// surface makes both harder to read.
  final bool selected;

  /// Position in the reorderable list, when this row is one that can be dragged
  /// — pinned rows only. The pin itself becomes the handle: it is the mark that
  /// says why this row is allowed to move, a long press is already taken by
  /// selection, and making the whole row a handle would mean the list could no
  /// longer be scrolled by starting on a pinned chat.
  final int? reorderIndex;

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
          Stack(
            children: [
              PeerAvatar(
                peerId: chat.peerId,
                label: chat.peerName,
                size: 48,
                online: chat.isOnline,
              ),
              // Grows in and shrinks out rather than appearing between two
              // frames. Picking chats out was the one place in the app where
              // something the finger did landed as a jump; the timing is the
              // nav bar's, so the two read as the same app.
              Positioned(
                right: 0,
                bottom: 0,
                child: AnimatedScale(
                  scale: selected ? 1 : 0,
                  duration: const Duration(milliseconds: 220),
                  curve: selected ? Curves.easeOutBack : Curves.easeInCubic,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.brandPrimary,
                      border: Border.all(color: AppColors.bgDeep, width: 2),
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      size: 12,
                      color: Colors.black,
                    ),
                  ),
                ),
              ),
              // Bottom *left*: the presence dot owns the other corner, and a
              // timer stacked on it would be two states in one place.
              if (chat.autoDeletes)
                Positioned(
                  left: 0,
                  bottom: 0,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.bgDeep,
                      border: Border.all(
                        color: AppColors.brandPrimary.withValues(alpha: 0.55),
                        width: 1,
                      ),
                    ),
                    child: Icon(
                      Icons.timer_outlined,
                      size: 11,
                      color: AppColors.brandPrimary,
                    ),
                  ),
                ),
            ],
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
                    // Next to the name, because it is the name that stays
                    // quiet. Dim and small: it explains a silence, it is not an
                    // alert of its own.
                    if (chat.isMuted) ...[
                      const SizedBox(width: 4),
                      Icon(
                        Icons.notifications_off_rounded,
                        color: AppColors.textOnGlassFaint,
                        size: 13,
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
              if (chat.unreadCount > 0 || chat.isPinned || chat.isFavorite) ...[
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (chat.isPinned) _PinMark(reorderIndex: reorderIndex),
                    if (chat.isFavorite)
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Icon(
                          Icons.star_rounded,
                          color: AppColors.warning,
                          size: 13,
                        ),
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

/// The pin, and — when the list it is in can be reordered — the grip that moves
/// the row.
///
/// A drag has to start from something small enough that the list can still be
/// scrolled from anywhere else, and obvious enough to be found. The pin is
/// already on exactly the rows that are allowed to move, so it is both; it
/// simply gets a finger-sized area around it, which it did not have at 13px.
class _PinMark extends StatelessWidget {
  const _PinMark({required this.reorderIndex});

  final int? reorderIndex;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      Icons.push_pin_rounded,
      color: AppColors.brandPrimary,
      size: reorderIndex == null ? 13 : 15,
    );
    if (reorderIndex == null) {
      return Padding(padding: const EdgeInsets.only(right: 4), child: icon);
    }
    return ReorderableDragStartListener(
      index: reorderIndex!,
      child: Padding(
        padding: const EdgeInsets.only(right: 2, left: 6, top: 6, bottom: 6),
        child: icon,
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
