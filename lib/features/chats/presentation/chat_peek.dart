import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/glass.dart';
import '../../../core/theme/typography.dart';
import '../../../core/utils/time_format.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/data/messages_controller.dart';
import '../../chat/models/message.dart';
import '../../chat/presentation/widgets/message_bubble.dart';
import '../../peers/data/known_peers_controller.dart';
import '../../peers/presentation/widgets/peer_avatar.dart';
import '../data/pinned_chats_controller.dart';
import '../data/read_markers_controller.dart';
import '../models/chat.dart';

/// A look at a conversation that does not count as having read it.
///
/// ## What it is for
///
/// The unread badge and the read receipt are the same decision made twice: open
/// a chat and the badge clears here while a receipt goes out there. That is
/// usually right and occasionally exactly wrong — checking whether something
/// needs answering now is not the same as answering it, and neither the badge
/// nor the other person should be told otherwise.
///
/// Read receipts could already be withheld, globally in Privacy and per person
/// in a contact's profile. What could not be done was look without *locally*
/// losing the place, which is the half this adds.
///
/// ## Why it does not open the chat screen
///
/// `ChatScreen` marks the conversation read on open, on resume, and on new
/// mail arriving while it is on top — three separate paths, each correct for
/// what that screen is. Suppressing all three behind a flag would leave the
/// most privacy-carrying behaviour in the app depending on a boolean threaded
/// through four thousand lines. This renders the messages itself instead, and
/// the property holds because nothing here can mark anything.
///
/// ## Why the bubbles are inert
///
/// Every bubble is wrapped in an [IgnorePointer]. A peek looks; it does not
/// react, open media, or consume a view-once photo — and that last one is not a
/// hypothetical, since viewing is exactly what spends a view-once message. The
/// list still scrolls, because the `Scrollable` is the parent and it is the
/// parent that handles the drag.
///
/// [onOpen] and [onDelete] are handed in rather than built here. Both already
/// exist in the list this is opened from — one knows the route, the other is
/// the dialog that offers to retract our messages from the other phone as well
/// — and a second implementation of a destructive path is how the two drift.
Future<void> showChatPeek(
  BuildContext context,
  Chat chat, {
  required VoidCallback onOpen,
  required VoidCallback onDelete,
}) {
  return Navigator.of(context, rootNavigator: true).push<void>(
    _ChatPeekRoute(chat, onOpen: onOpen, onDelete: onDelete),
  );
}

class _ChatPeekRoute extends PopupRoute<void> {
  _ChatPeekRoute(this.chat, {required this.onOpen, required this.onDelete});

  final Chat chat;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Chat preview';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 220);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 170);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      _ChatPeekView(chat: chat, onOpen: onOpen, onDelete: onDelete);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // Grows from slightly under full size rather than sliding: the row it came
    // from is still visible behind the blur, and a slide would argue with the
    // list scrolling underneath. Honours the platform's reduce-motion setting,
    // where it becomes a plain fade.
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final faded = FadeTransition(opacity: curved, child: child);
    if (reduce) return faded;
    return ScaleTransition(
      scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
      child: faded,
    );
  }
}

class _ChatPeekView extends ConsumerWidget {
  const _ChatPeekView({
    required this.chat,
    required this.onOpen,
    required this.onDelete,
  });

  final Chat chat;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final messages =
        ref.watch(messagesControllerProvider)[chat.id] ?? const <Message>[];

    // Transparent Material, and it is not decoration.
    //
    // A PopupRoute has no Material of its own, and text with no Material above
    // it falls back to the debug style Flutter draws with a yellow double
    // underline — every label on this screen wore one. The same ancestor is
    // what lets the InkWell in the action rows paint a ripple, so one wrapper
    // fixes the look and the touch feedback together. Transparent because the
    // glass islands underneath already own every surface here.
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          // One full-screen blur, and only while this is open. The three
          // permanent BackdropFilters a conversation carries are the measured
          // cost in this app; a fourth that exists for two seconds at a time is
          // not the same kind of expense, so it uses the shared sigma rather
          // than a constant of its own.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).maybePop(),
              child: BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: AppBlur.sigma,
                  sigmaY: AppBlur.sigma,
                ),
                child: ColoredBox(color: Colors.black.withValues(alpha: 0.38)),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Column(
                children: [
                  _PeekHeader(chat: chat),
                  const SizedBox(height: 8),
                  Expanded(
                    child: messages.isEmpty
                        ? const SizedBox.shrink()
                        : _PeekConversation(chat: chat, messages: messages),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    t.chatPeekUnreadNotice,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textOnGlassFaint,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 6),
                  _PeekActions(chat: chat, onOpen: onOpen, onDelete: onDelete),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Who this is, in the same shape the chat header uses.
class _PeekHeader extends StatelessWidget {
  const _PeekHeader({required this.chat});

  final Chat chat;

  @override
  Widget build(BuildContext context) {
    return FloatingGlass(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          PeerAvatar(
            peerId: chat.peerId,
            label: chat.peerName,
            size: 40,
            online: chat.isOnline,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  chat.peerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.heading(
                    size: 16,
                    color: AppColors.textOnGlass,
                  ),
                ),
                if (chat.unreadCount > 0)
                  Text(
                    '${chat.unreadCount}',
                    style: TextStyle(
                      color: AppColors.brandPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The conversation, scrollable and untouchable.
class _PeekConversation extends StatelessWidget {
  const _PeekConversation({required this.chat, required this.messages});

  final Chat chat;
  final List<Message> messages;

  @override
  Widget build(BuildContext context) {
    // Reversed, so it opens on the newest message the way the chat does and so
    // scrolling back through the whole history costs nothing until it is asked
    // for. Index 0 is therefore the last message.
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: messages.length,
      itemBuilder: (context, i) {
        final index = messages.length - 1 - i;
        final message = messages[index];
        final previous = index == 0 ? null : messages[index - 1].sentAt;
        final opensDay = startsNewDay(message.sentAt, previous);
        final bubble = IgnorePointer(
          child: MessageBubble(message: message, chatId: chat.id),
        );
        if (!opensDay) return bubble;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                formatDayHeader(context, message.sentAt),
                style: TextStyle(
                  color: AppColors.textOnGlassDim,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            bubble,
          ],
        );
      },
    );
  }
}

/// The things worth doing without opening the conversation.
///
/// The same vocabulary the swipe actions and the selection bar already use, so
/// there is one set of things a chat can have done to it rather than three.
/// Deliberately no reply: answering is the one action that genuinely *is*
/// reading it, and offering it here would quietly undo the point.
class _PeekActions extends ConsumerWidget {
  const _PeekActions({
    required this.chat,
    required this.onOpen,
    required this.onDelete,
  });

  final Chat chat;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final pinned = ref.watch(pinnedChatsControllerProvider).contains(chat.id);
    final muted = chat.isMuted;
    final unread = chat.unreadCount > 0;

    return FloatingGlass(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PeekAction(
            icon: Icons.chat_bubble_outline_rounded,
            label: t.chatPeekOpen,
            onTap: () {
              Navigator.of(context).pop();
              onOpen();
            },
          ),
          if (unread)
            _PeekAction(
              icon: Icons.mark_chat_read_rounded,
              label: t.chatPeekMarkRead,
              onTap: () async {
                await ref
                    .read(readMarkersControllerProvider.notifier)
                    .markRead(chat.id);
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
          _PeekAction(
            icon: pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
            label: pinned ? t.chatPeekUnpin : t.chatPeekPin,
            onTap: () async {
              final pins = ref.read(pinnedChatsControllerProvider.notifier);
              await (pinned ? pins.unpin(chat.id) : pins.pin(chat.id));
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
          _PeekAction(
            icon: muted
                ? Icons.notifications_active_rounded
                : Icons.notifications_off_rounded,
            label: muted ? t.chatPeekUnmute : t.channelMute,
            onTap: () async {
              await ref
                  .read(knownPeersControllerProvider.notifier)
                  .setMuted(chat.id, !muted);
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
          _PeekAction(
            icon: Icons.delete_outline_rounded,
            label: t.chatsActionDelete,
            danger: true,
            // Closed first, then the list asks. The dialog belongs to the
            // screen underneath — it offers to retract our messages from the
            // other phone too — and asking from behind a blur that is about to
            // be torn down puts a question on top of something disappearing.
            onTap: () {
              Navigator.of(context).pop();
              onDelete();
            },
          ),
        ],
      ),
    );
  }
}

class _PeekAction extends StatelessWidget {
  const _PeekAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.danger : AppColors.textOnGlass;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Icon(icon, color: color, size: 21),
            const SizedBox(width: 16),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
