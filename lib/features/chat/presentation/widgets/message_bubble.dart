import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/transport/messaging_service.dart';
import '../../../../core/utils/time_format.dart';
import '../../../../core/widgets/context_popup.dart';
import '../../../../core/widgets/floating_glass.dart';
import '../../../../core/widgets/glass_toast.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../chats/models/chat.dart';
import '../../../chats/presentation/chats_list_screen.dart' show chatsProvider;
import '../../data/message_edit_target.dart';
import '../../data/message_reply_target.dart';
import '../../data/messages_controller.dart';
import '../../models/message.dart';
import '../chat_media_gallery_screen.dart';
import 'voice_bubble.dart';

/// Emoji offered in the long-press reaction picker. Kept short so the row fits
/// one line on a narrow phone.
const _reactionChoices = ['👍', '❤️', '😂', '😮', '😢', '🔥'];

class MessageBubble extends ConsumerStatefulWidget {
  const MessageBubble({super.key, required this.message, required this.chatId});

  final Message message;

  /// The chat this bubble lives in (pubkey-hex peer id or `#channel`). Needed
  /// to route a reaction back over the wire.
  final String chatId;

  @override
  ConsumerState<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends ConsumerState<MessageBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  )..forward();

  late final Animation<double> _scale =
      CurvedAnimation(parent: _c, curve: Curves.easeOutBack);
  late final Animation<double> _fade =
      CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.15),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  bool get _canReact => widget.message.wireId != null;

  /// Anything with words in it can be copied — including the caption on a
  /// photo. A voice note or a bare image has nothing to put on the clipboard.
  bool get _canCopy => widget.message.text.trim().isNotEmpty;

  /// Forwarding re-sends the text into another chat, so it needs text for the
  /// same reason [_canCopy] does. Media isn't forwarded: the bytes live in a
  /// chat-scoped file and re-sending them is a different job from this one.
  bool get _canForward => _canCopy;

  /// Only your own text messages can be rewritten, and only if we know the
  /// transport id everyone else filed them under.
  bool get _canEdit =>
      widget.message.isMine &&
      widget.message.kind == MessageKind.text &&
      widget.message.wireId != null;

  void _toggleReaction(String emoji) {
    final mineSet = widget.message.reactions[emoji];
    final alreadyMine = mineSet != null && mineSet.contains('me');
    ref.read(messagingServiceProvider).sendReaction(
          widget.chatId,
          widget.message.wireId!,
          emoji,
          add: !alreadyMine,
        );
  }

  /// Telegram-style long-press menu: a small popup anchored at the finger,
  /// floating above everything. A reaction strip on top (when the message can
  /// carry reactions), then the per-message actions.
  Future<void> _showActions(Offset at) async {
    final t = AppLocalizations.of(context);

    final picked = await showContextPopup<String>(
      context: context,
      globalPosition: at,
      items: [
        if (_canReact)
          PopupMenuItem<String>(
            enabled: false,
            padding: EdgeInsets.zero,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                for (final e in _reactionChoices)
                  // Builder so the pop targets the menu route, not this bubble.
                  Builder(
                    builder: (ctx) => InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: () => Navigator.of(ctx).pop('r:$e'),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text(e, style: const TextStyle(fontSize: 22)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (widget.message.wireId != null)
          _menuRow(
              'reply', Icons.reply, t.chatReplyAction, AppColors.textOnGlass),
        if (_canCopy)
          _menuRow('copy', Icons.copy_outlined, t.chatCopyAction,
              AppColors.textOnGlass),
        if (_canForward)
          _menuRow('forward', Icons.shortcut_outlined, t.chatForwardAction,
              AppColors.textOnGlass),
        if (_canEdit)
          _menuRow('edit', Icons.edit_outlined, t.chatEditAction,
              AppColors.textOnGlass),
        _menuRow('delete', Icons.delete_outline, t.chatDeleteAction,
            AppColors.danger),
      ],
    );

    if (picked == null || !mounted) return;
    if (picked.startsWith('r:')) {
      _toggleReaction(picked.substring(2));
    } else if (picked == 'reply') {
      final m = widget.message;
      ref.read(messageReplyTargetProvider.notifier).state = MessageReplyTarget(
        chatId: widget.chatId,
        wireId: m.wireId!,
        preview: _replyPreview(m),
        mine: m.isMine,
        authorName: m.authorName,
      );
    } else if (picked == 'copy') {
      await Clipboard.setData(ClipboardData(text: widget.message.text));
      if (!mounted) return;
      showCopiedToast(context, t.chatCopied);
    } else if (picked == 'forward') {
      await _promptForward();
    } else if (picked == 'edit') {
      // Load the message into the input row (Telegram-style inline edit); the
      // input commits it on send.
      ref.read(messageEditTargetProvider.notifier).state = MessageEditTarget(
        chatId: widget.chatId,
        wireId: widget.message.wireId!,
        originalText: widget.message.text,
      );
    } else if (picked == 'delete') {
      await _promptDelete();
    }
  }

  /// The message [wireId] quotes, resolved from this chat's list, or null if
  /// it's not in memory (e.g. cleared history or arrived out of order).
  Message? _resolveQuoted(String wireId) {
    final list = ref.watch(messagesControllerProvider)[widget.chatId];
    if (list == null) return null;
    for (final m in list) {
      if (m.wireId == wireId) return m;
    }
    return null;
  }

  /// The quote box shown at the top of a reply bubble.
  Widget _quotedBox(String wireId) {
    final quoted = _resolveQuoted(wireId);
    final preview = quoted == null ? '…' : _replyPreview(quoted);
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(color: AppColors.brandPrimary, width: 2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (quoted?.authorName != null)
            Text(
              quoted!.authorName!,
              style: TextStyle(
                color: AppColors.brandPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          Text(
            preview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.textOnGlassDim,
              fontSize: 12.5,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  /// A one-line snippet of [m] for a reply preview / quote box.
  static String _replyPreview(Message m) {
    switch (m.kind) {
      case MessageKind.image:
        return '📷';
      case MessageKind.audio:
        return '🎤';
      case MessageKind.text:
        final t = m.text.replaceAll('\n', ' ').trim();
        return t.length > 80 ? '${t.substring(0, 80)}…' : t;
    }
  }

  PopupMenuItem<String> _menuRow(
    String value,
    IconData icon,
    String label,
    Color color,
  ) {
    return PopupMenuItem<String>(
      value: value,
      height: 44,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 19, color: color),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  /// Pick a chat and re-send this message's text into it.
  ///
  /// Forwarding is a fresh send, not a relay of the original frame: the text
  /// goes out under our own identity, signed and sealed for the new recipient.
  /// That is the only shape that works here — the original is encrypted to a
  /// session the new chat has no key for, so it could not be passed along even
  /// if we wanted to.
  Future<void> _promptForward() async {
    final t = AppLocalizations.of(context);
    // Every chat except the one we're standing in.
    final targets =
        ref.read(chatsProvider).where((c) => c.id != widget.chatId).toList();

    final chosen = await showDialog<Chat>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: AppColors.bgTop,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
        ),
        title: Text(
          t.chatForwardTitle,
          style: TextStyle(
            color: AppColors.textOnGlass,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        children: [
          if (targets.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
              child: Text(
                t.chatForwardEmpty,
                style: TextStyle(color: AppColors.textOnGlassDim),
              ),
            )
          else
            // Bounded so a long chat list scrolls inside the dialog instead of
            // overflowing it.
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.4,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final c in targets)
                      SimpleDialogOption(
                        onPressed: () => Navigator.of(ctx).pop(c),
                        child: Row(
                          children: [
                            Icon(
                              c.isChannel ? Icons.tag : Icons.person_outline,
                              size: 18,
                              color: AppColors.textOnGlassDim,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                c.peerName,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: AppColors.textOnGlass),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t.cancel,
                style: TextStyle(color: AppColors.textOnGlassDim)),
          ),
        ],
      ),
    );

    if (chosen == null || !mounted) return;

    final messaging = ref.read(messagingServiceProvider);
    final text = widget.message.text;
    if (chosen.isChannel) {
      await messaging.sendChannelText(chosen.id, text);
    } else {
      await messaging.sendText(chosen.id, text);
    }
    if (!mounted) return;
    showGlassToast(
      context,
      t.chatForwardSent(chosen.peerName),
      icon: Icons.shortcut_outlined,
      tone: ToastTone.success,
    );
  }

  Future<void> _promptDelete() async {
    final t = AppLocalizations.of(context);
    final m = widget.message;
    // "For everyone" only makes sense for our own message, and only when we
    // know the shared id the recipients filed it under.
    final canForEveryone = m.isMine && m.wireId != null;

    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: AppColors.bgTop,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
        ),
        title: Text(
          t.chatDeleteTitle,
          style: TextStyle(
            color: AppColors.textOnGlass,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        children: [
          if (canForEveryone)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop('everyone'),
              child: Text(t.chatDeleteForEveryone,
                  style: const TextStyle(color: AppColors.danger)),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('me'),
            child: Text(t.chatDeleteForMe,
                style: TextStyle(color: AppColors.textOnGlass)),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t.cancel,
                style: TextStyle(color: AppColors.textOnGlassDim)),
          ),
        ],
      ),
    );

    if (choice == 'me') {
      ref
          .read(messagesControllerProvider.notifier)
          .deleteLocal(widget.chatId, m.id);
    } else if (choice == 'everyone') {
      await ref
          .read(messagingServiceProvider)
          .sendDeleteForEveryone(widget.chatId, m.wireId!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final mine = message.isMine;

    final radius = BorderRadius.only(
      topLeft: const Radius.circular(18),
      topRight: const Radius.circular(18),
      bottomLeft: Radius.circular(mine ? 18 : 6),
      bottomRight: Radius.circular(mine ? 6 : 18),
    );
    // Each bubble is its own levitating island, the same principle the chat
    // list and the nav bar use — nothing welded behind it, just a pane over the
    // aurora. It can't be a FloatingGlass (that surface is deliberately neutral
    // and these have to stay colour-coded by sender), so it wears the shared
    // shadow recipe over its own fill.
    //
    // The RepaintBoundary is not decoration: the BackdropFilter below was
    // already here, and without a boundary one bubble's blur repaints its
    // neighbours on every scroll frame. It makes the list cheaper than before,
    // which matters on the same phones this branch is trying to cool down.
    final bubble = RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: FloatingGlass.shadows,
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: mine
                  ? BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          AppColors.brandPrimary.withValues(alpha: 0.85),
                          AppColors.brandSecondary.withValues(alpha: 0.85),
                        ],
                      ),
                      borderRadius: radius,
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.18)),
                    )
                  : BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.10),
                      borderRadius: radius,
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.16)),
                    ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Channel messages from others: show the author's name on top,
                  // since a channel mixes many senders in one conversation.
                  if (!mine && message.authorName != null) ...[
                    Text(
                      message.authorName!,
                      style: TextStyle(
                        color: AppColors.brandPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                  ],
                  if (message.replyToWireId != null)
                    _quotedBox(message.replyToWireId!),
                  if (message.kind == MessageKind.image)
                    _ImagePayload(message: message, chatId: widget.chatId)
                  else if (message.kind == MessageKind.audio)
                    VoiceBubble(message: message)
                  else
                    Text(
                      message.text,
                      style: TextStyle(
                        color: AppColors.textOnGlass,
                        fontSize: 14.5,
                        height: 1.35,
                      ),
                    ),
                  const SizedBox(height: 4),
                  _BubbleMeta(message: message),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.92, end: 1.0).animate(_scale),
          alignment: mine ? Alignment.bottomRight : Alignment.bottomLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
            child: Row(
              mainAxisAlignment:
                  mine ? MainAxisAlignment.end : MainAxisAlignment.start,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                      maxWidth: MediaQuery.sizeOf(context).width * 0.75),
                  child: Column(
                    crossAxisAlignment: mine
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        onLongPressStart: (d) => _showActions(d.globalPosition),
                        child: bubble,
                      ),
                      if (message.reactions.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: _ReactionsRow(
                            reactions: message.reactions,
                            onTap: _canReact ? _toggleReaction : null,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Row of reaction chips shown under a bubble. Each chip is `emoji ×count`
/// (count hidden when 1); a chip the local user contributed to is tinted.
class _ReactionsRow extends StatelessWidget {
  const _ReactionsRow({required this.reactions, required this.onTap});

  final Map<String, Set<String>> reactions;
  final void Function(String emoji)? onTap;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final entry in reactions.entries)
          if (entry.value.isNotEmpty)
            _ReactionChip(
              emoji: entry.key,
              count: entry.value.length,
              mine: entry.value.contains('me'),
              onTap: onTap == null ? null : () => onTap!(entry.key),
            ),
      ],
    );
  }
}

class _ReactionChip extends StatelessWidget {
  const _ReactionChip({
    required this.emoji,
    required this.count,
    required this.mine,
    required this.onTap,
  });

  final String emoji;
  final int count;
  final bool mine;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: mine
              ? AppColors.brandPrimary.withValues(alpha: 0.22)
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: mine
                ? AppColors.brandPrimary.withValues(alpha: 0.6)
                : Colors.white.withValues(alpha: 0.14),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 13)),
            if (count > 1) ...[
              const SizedBox(width: 4),
              Text(
                '$count',
                style: TextStyle(
                  color: AppColors.textOnGlass,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// In-bubble image rendering. While the bytes are still in flight (sender
/// hasn't finished chunking, or receiver hasn't reassembled), shows a
/// placeholder block with a spinner — the bubble still occupies space so
/// the list doesn't reflow when the image finally appears.
class _ImagePayload extends StatelessWidget {
  const _ImagePayload({required this.message, required this.chatId});

  final Message message;
  final String chatId;

  @override
  Widget build(BuildContext context) {
    final path = message.imagePath;
    final fileExists = path != null && File(path).existsSync();

    final heroTag = 'image-${message.id}';
    final body = fileExists
        ? GestureDetector(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                fullscreenDialog: true,
                builder: (_) => ChatMediaGalleryScreen(
                  chatId: chatId,
                  initialMessageId: message.id,
                ),
              ),
            ),
            child: Hero(
              tag: heroTag,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _ImagePlaceholder(
                    icon: Icons.broken_image_outlined,
                    label: message.imageMime ?? 'image',
                  ),
                ),
              ),
            ),
          )
        : _ImagePlaceholder(
            icon: message.status == MessageStatus.failed
                ? Icons.broken_image_outlined
                : Icons.image_outlined,
            label: message.imageMime ?? message.text,
            spinning: message.status == MessageStatus.sending,
          );

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220, maxHeight: 220),
      child: body,
    );
  }
}

class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder({
    required this.icon,
    required this.label,
    this.spinning = false,
  });

  final IconData icon;
  final String label;
  final bool spinning;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      height: 140,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (spinning)
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.brandPrimary,
              ),
            )
          else
            Icon(icon, color: AppColors.textOnGlassDim, size: 28),
          const SizedBox(height: 8),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _BubbleMeta extends StatelessWidget {
  const _BubbleMeta({required this.message});

  final Message message;

  /// Distinct tint for a "read" tick so it reads apart from plain delivery.
  static const _readColor = Color(0xFF66D9FF);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final time = formatBubbleTime(context, message.sentAt);

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (message.forwardSecret) ...[
          Icon(
            Icons.lock_clock,
            size: 11,
            color: Colors.white.withValues(alpha: message.isMine ? 0.8 : 0.55),
            semanticLabel: 'forward secret',
          ),
          const SizedBox(width: 4),
        ],
        if (message.editedAt != null) ...[
          Text(
            t.chatEdited,
            style: TextStyle(
              fontSize: 10.5,
              fontStyle: FontStyle.italic,
              color:
                  Colors.white.withValues(alpha: message.isMine ? 0.7 : 0.45),
            ),
          ),
          const SizedBox(width: 4),
        ],
        Text(
          time,
          style: TextStyle(
            fontSize: 10.5,
            color: Colors.white.withValues(alpha: message.isMine ? 0.8 : 0.5),
          ),
        ),
        if (message.isMine) ...[
          const SizedBox(width: 4),
          Icon(
            switch (message.status) {
              MessageStatus.sending => Icons.schedule,
              MessageStatus.delivered => Icons.done,
              MessageStatus.read => Icons.done_all,
              MessageStatus.failed => Icons.error_outline,
            },
            size: 12,
            color: switch (message.status) {
              MessageStatus.failed => AppColors.danger,
              MessageStatus.read => _readColor,
              _ => Colors.white.withValues(alpha: 0.85),
            },
            semanticLabel: switch (message.status) {
              MessageStatus.sending => t.chatSending,
              MessageStatus.delivered => t.chatDelivered,
              MessageStatus.read => t.chatRead,
              MessageStatus.failed => '!',
            },
          ),
        ],
      ],
    );
  }
}
