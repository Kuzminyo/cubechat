import 'package:flutter/material.dart';
import '../../../../core/theme/typography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/colors.dart';
import '../../../peers/data/presence_controller.dart';
import '../../../../core/utils/time_format.dart';
import '../../../../core/widgets/unread_badge.dart';
import '../../../chat/models/message.dart';
import '../../../peers/data/typing_controller.dart';
import '../../../peers/presentation/widgets/peer_avatar.dart';
import '../../../../l10n/app_localizations.dart';
import '../../models/chat.dart';

/// The contents of one chat row: avatar, name + status, and last-message
/// preview. It paints no surface of its own — the [FloatingGlass] island the
/// list wraps it in owns the background, tap ripple and long-press.
class ChatTile extends ConsumerWidget {
  const ChatTile({
    super.key,
    required this.chat,
    this.selected = false,
    this.reorderIndex,
    this.onAvatarLongPress,
  });

  final Chat chat;

  /// Picked out for a bulk action — see `chatSelectionProvider`. Marked on the
  /// avatar rather than by tinting the row: the row's own colours already say
  /// whether there is something unread in it, and a second meaning on the same
  /// surface makes both harder to read.
  final bool selected;

  /// Position in the reorderable list, when this row is one that can be dragged
  /// — a pinned row, while the list is in the mode a long press puts it in.
  /// Null everywhere else, which is also what withholds the grip: no grip, no
  /// way to start a drag, so an ordinary scroll that begins on a pinned chat
  /// stays a scroll.
  final int? reorderIndex;

  /// Hold the picture to look inside without opening — see `showChatPeek`.
  ///
  /// On the avatar rather than on the row, and that is forced rather than
  /// chosen: holding the row is what puts the list into the mode where a
  /// pinned row grows its drag handle, and a menu was already tried there once
  /// and taken back out for stealing it. The avatar is a 48-point target
  /// inside a row that is doing something else with the same gesture, so the
  /// two never meet.
  ///
  /// Null while a selection is running, which leaves the hold to the row.
  final VoidCallback? onAvatarLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    // Watched through `select` so a notice about one person repaints one row.
    // Watching the whole map would rebuild every row in the list every few
    // seconds for as long as anybody, anywhere, is writing — and this row
    // carries an avatar and a formatted time, so it is not free.
    //
    // Channels are excluded because typing is 1:1 on the wire (see
    // `InnerPayloadType.typing`); their ids can never appear in the map, and
    // saying so here keeps a future room-typing feature from silently
    // half-working.
    final typingAt = chat.isChannel
        ? null
        : ref.watch(typingControllerProvider.select((m) => m[chat.id]));
    final isTyping = typingAt != null &&
        DateTime.now().difference(typingAt) < TypingController.ttl;
    // Watched here, one key at a time, rather than carried in on the row.
    //
    // Presence used to be a field on `Chat`, computed by `allChatsProvider`
    // from the whole presence map — so a beacon about one person rebuilt every
    // preview string, every unread count and the sort. This narrows that to the
    // one avatar the beacon is about. A channel has no presence at all and must
    // not open a subscription pretending otherwise.
    final isOnline =
        chat.isChannel ? false : ref.watch(peerOnlineProvider(chat.peerId));
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
          GestureDetector(
            // The inner detector wins the arena against the row's own hold,
            // which is what makes this work at all. `behavior` is opaque so a
            // hold that lands on the transparent corner of the circle still
            // counts as the avatar rather than falling through to the row.
            behavior: HitTestBehavior.opaque,
            onLongPress: onAvatarLongPress,
            child: Stack(
              children: [
                PeerAvatar(
                  peerId: chat.peerId,
                  label: chat.peerName,
                  size: 48,
                  online: isOnline,
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
                        Icons.timer_rounded,
                        size: 11,
                        color: AppColors.brandPrimary,
                      ),
                    ),
                  ),
              ],
            ),
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
                        style: AppTypography.rowTitle.copyWith(
                          fontWeight:
                              unread ? FontWeight.w700 : FontWeight.w600,
                        ),
                      ),
                    ),
                    if (chat.isVerified) ...[
                      const SizedBox(width: 4),
                      Icon(
                        Icons.verified_rounded,
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
                    ],
                    // No "via mesh" pill either.
                    //
                    // It said something true and useless: that a radio link to
                    // this person exists. Nobody reading a list of
                    // conversations is asking which road a message would take
                    // — that question belongs to the chat, where the header
                    // answers it, and it is answered there per message rather
                    // than as a standing label. On the list it was a bright
                    // badge that appeared and vanished as people wandered in
                    // and out of range, on rows whose content had not changed.
                    //
                    // Removed for the same reason there is no "offline" pill:
                    // a lot of ink for a state nobody was asking about.
                    // No "offline" pill. The dot on the avatar already says
                    // who is here, and its absence says the rest — spelling it
                    // out put a grey badge on almost every row, which is a lot
                    // of ink for the state a list is usually in.
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  // Ahead of the draft, and for the same reason it goes ahead
                  // of "online" in the chat header: a draft is a note to
                  // yourself that will still be there in an hour, and this is
                  // the other person doing something right now. Only one line
                  // exists, so the live fact takes it.
                  isTyping
                      ? t.chatTyping
                      : chat.isDraft
                          ? '${t.chatDraft}: ${chat.lastMessage}'
                          : chat.lastMessage,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isTyping || chat.isDraft
                        ? AppColors.brandPrimary
                        : unread
                            ? AppColors.textOnGlass
                            : AppColors.textOnGlassDim,
                    fontSize: 14,
                    height: 1.35,
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
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Before the time, the way it is in the bubble and in every
                  // other list of conversations: the row already answers "when"
                  // and "who last spoke", and this is the third question people
                  // open a chat to check — whether the last thing they said got
                  // there.
                  if (chat.outgoingStatus case final status?) ...[
                    _StatusTick(status: status),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    formatChatListTime(context, chat.lastTime),
                    style: AppTypography.caption,
                  ),
                ],
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
                    if (chat.isPinned) const _PinMark(),
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
          // Only on the rows that can actually move — the pinned block.
          if (reorderIndex case final index?) ...[
            const SizedBox(width: 2),
            _DragGrip(index: index),
          ],
        ],
      ),
    );
  }
}

/// One tick sent, two delivered, two tinted read — the same glyphs and the same
/// colours the bubble uses, so the mark means the same thing in both places.
class _StatusTick extends StatelessWidget {
  const _StatusTick({required this.status});

  final MessageStatus status;

  /// Matches `_BubbleMeta._readColor`. Copied rather than shared because that
  /// one is private to the bubble and this is the only other place it appears;
  /// if a third turns up it should move somewhere common.
  static const _readColor = Color(0xFF66D9FF);

  @override
  Widget build(BuildContext context) {
    return Icon(
      switch (status) {
        MessageStatus.sending => Icons.schedule_rounded,
        MessageStatus.delivered => Icons.done_rounded,
        MessageStatus.read => Icons.done_all_rounded,
        MessageStatus.failed => Icons.error_outline_rounded,
      },
      size: 13,
      color: switch (status) {
        MessageStatus.failed => AppColors.danger,
        MessageStatus.read => _readColor,
        _ => AppColors.textOnGlassFaint,
      },
    );
  }
}

/// The mark that says this row is pinned. Just the mark — dragging is the
/// [_DragGrip] at the end of the row.
class _PinMark extends StatelessWidget {
  const _PinMark();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Icon(
        Icons.push_pin_rounded,
        color: AppColors.brandPrimary,
        size: 13,
      ),
    );
  }
}

/// The two bars at the trailing edge of a pinned row that the row is dragged
/// by.
///
/// The pin itself used to be the handle, which failed twice over. It is 13
/// points of icon inside 25 of padding, tucked under the timestamp among the
/// unread badge and the star — too small to hit reliably, which is what "the
/// drag works every other time" was — and nothing about a pin says "pull me".
/// So the grip is now its own thing: the standard two-bar glyph, at the end of
/// the row where every list in every app puts one, in a target the width of a
/// thumb.
class _DragGrip extends StatelessWidget {
  const _DragGrip({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    return ReorderableDragStartListener(
      index: index,
      child: SizedBox(
        width: 34,
        height: 52,
        child: Icon(
          Icons.drag_handle_rounded,
          size: 22,
          color: AppColors.textOnGlassFaint,
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
