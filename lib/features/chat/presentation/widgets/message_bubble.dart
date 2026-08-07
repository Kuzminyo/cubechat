import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:go_router/go_router.dart';
import '../../../../core/routing/page_transitions.dart';
import '../../../../core/theme/colors.dart';
import '../../../../core/transport/messaging_service.dart';
import '../../../../core/transport/shared_contact.dart';
import '../../../../core/utils/time_format.dart';
import '../../../../core/widgets/context_popup.dart';
import '../../../../core/widgets/floating_glass.dart';
import '../../../../core/widgets/glass_toast.dart';
import '../../../../core/widgets/pop_on_change.dart';
import '../../../peers/presentation/widgets/peer_avatar.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../chats/models/chat.dart';
import '../../../chats/presentation/chats_list_screen.dart' show chatsProvider;
import '../../data/chat_navigation.dart';
import '../../data/message_selection.dart';
import '../../data/conversation_settings_controller.dart';
import '../../data/message_edit_target.dart';
import '../../data/message_reply_target.dart';
import '../../data/messages_controller.dart';
import '../../data/pinned_controller.dart';
import '../../data/reaction_emoji_controller.dart';
import 'emoji_picker_sheet.dart';
import '../../models/message.dart';
import '../chat_media_gallery_screen.dart';
import '../view_once_media_screen.dart';
import 'file_bubble.dart';
import 'poll_bubble.dart';
import 'mention_text.dart';
import 'voice_bubble.dart';

/// How far a bubble follows a leftward drag before it stops moving, and how far
/// it has to travel for the release to mean "reply".
///
/// The gap between the two is deliberate: the bubble keeps moving a little
/// after the threshold so there is visible confirmation the gesture took, and
/// the hint icon has somewhere to finish arriving.
bool messageCanBeCopied(
  Message message, {
  required bool copyingRestricted,
}) =>
    // A view-once photo is excluded even though its *caption* is text and
    // these two are gated on text. The bytes never leave either way, but
    // offering Copy and Forward on something the app has just promised to
    // destroy reads as the promise not being meant.
    !copyingRestricted && !message.viewOnce && message.text.trim().isNotEmpty;

bool messageCanBeForwarded(
  Message message, {
  required bool copyingRestricted,
}) =>
    messageCanBeCopied(
      message,
      copyingRestricted: copyingRestricted,
    );

const double _swipeTrigger = 56;
const double _swipeMax = 76;

/// Ask which chat to forward into. Null when the dialog was dismissed.
///
/// Shared by the single-message menu and the multi-select bar so the two
/// cannot drift into offering different target lists.
Future<Chat?> pickForwardTarget(
  BuildContext context,
  WidgetRef ref,
  String fromChatId,
) {
  final t = AppLocalizations.of(context);
  // Every chat except the one we're standing in.
  final targets =
      ref.read(chatsProvider).where((c) => c.id != fromChatId).toList();

  return showDialog<Chat>(
    context: context,
    builder: (ctx) => SimpleDialog(
      backgroundColor: AppColors.bgTop,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: AppColors.glass(0.15)),
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
                            c.isChannel
                                ? Icons.campaign_rounded
                                : Icons.person_outline,
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
          child:
              Text(t.cancel, style: TextStyle(color: AppColors.textOnGlassDim)),
        ),
      ],
    ),
  );
}

/// Re-send [text] into [target] under our own identity.
///
/// Forwarding is a fresh send, not a relay of the original frame: the original
/// is encrypted to a session the new chat has no key for, so it could not be
/// passed along even if we wanted to.
Future<void> forwardTextTo(WidgetRef ref, Chat target, String text) {
  final messaging = ref.read(messagingServiceProvider);
  return target.isChannel
      ? messaging.sendChannelText(target.id, text)
      : messaging.sendText(target.id, text);
}

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
    with TickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  )..forward();

  /// Drives the spring back to rest after a swipe-to-reply, whether or not the
  /// gesture crossed the threshold.
  late final AnimationController _swipe = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(() {
      if (_swipeFrom == 0) return;
      setState(() {
        _dragX = _swipeFrom * (1 - Curves.easeOutCubic.transform(_swipe.value));
      });
    });

  /// Current horizontal offset of the bubble; never positive (this gesture only
  /// goes left) and never past [_swipeMax].
  double _dragX = 0;

  /// Where the spring started, so the animation can interpolate home.
  double _swipeFrom = 0;

  /// True once the drag is far enough that releasing would file a reply. Held
  /// separately from the offset so crossing the line can fire its own haptic
  /// exactly once.
  bool _armed = false;

  late final Animation<double> _scale =
      CurvedAnimation(parent: _c, curve: Curves.easeOutBack);
  late final Animation<double> _fade =
      CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.15),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));

  /// One-shot shower of emoji thrown over the bubble when a reaction is *added*.
  /// Idle for the entire life of the bubble apart from the ~600 ms it plays.
  late final AnimationController _burst = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  )..addStatusListener((s) {
      // Drops the painter out of the tree the moment it has nothing left to
      // draw, so a screen full of bubbles that have each been reacted to once
      // is not a screen full of dormant CustomPaints.
      if (s == AnimationStatus.completed && mounted) {
        setState(() => _burstEmoji = null);
      }
    });

  String? _burstEmoji;

  /// Bumped for an emoji whose tally moved while this bubble stayed on screen.
  ///
  /// A count is not enough on its own: a chip built with `count: 3` cannot tell
  /// whether it just went 2 → 3 or whether it has been 3 all along and the row
  /// was merely scrolled back into view. A revision only ever changes for the
  /// former, which is exactly what [PopOnChange] wants to watch.
  final Map<String, int> _reactionRev = {};

  /// Emoji whose chip appeared while the bubble was already on screen — the
  /// ones that get to pop themselves into existence. See [PopOnChange].
  final Set<String> _freshReactions = {};

  @override
  void didUpdateWidget(MessageBubble old) {
    super.didUpdateWidget(old);
    final before = old.message.reactions;
    for (final entry in widget.message.reactions.entries) {
      final was = before[entry.key]?.length ?? 0;
      if (was == entry.value.length) continue;
      if (was == 0) {
        // Brand new chip: it will be built for the first time in a moment, and
        // the flag is what tells it this build is an arrival rather than a
        // scroll. Never cleared — an element runs `initState` once, so a stale
        // entry cannot fire twice, and a reaction removed and re-added gets a
        // new element and should pop again anyway.
        _freshReactions.add(entry.key);
      } else {
        _reactionRev[entry.key] = (_reactionRev[entry.key] ?? 0) + 1;
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _swipe.dispose();
    _burst.dispose();
    super.dispose();
  }

  bool get _canReact => widget.message.wireId != null;

  /// A reply needs the transport id everyone else filed the message under, and
  /// somewhere to compose it — the composer only builds reply frames in 1:1,
  /// so offering the gesture in a channel would swallow it silently.
  bool get _canReply =>
      widget.message.wireId != null && !widget.chatId.startsWith('#');

  void _startReply() {
    final m = widget.message;
    ref.read(messageReplyTargetProvider.notifier).state = MessageReplyTarget(
      chatId: widget.chatId,
      wireId: m.wireId!,
      preview: _replyPreview(m),
      mine: m.isMine,
      authorName: m.authorName,
    );
  }

  /// Double-tap: the one-gesture path to the reaction people actually use —
  /// which is now the last one *they* used, not a constant in this file.
  void _quickReact() {
    if (!_canReact) return;
    HapticFeedback.lightImpact();
    _toggleReaction(
      ref.read(reactionEmojiControllerProvider.notifier).quickReaction,
    );
  }

  void _onSwipeUpdate(DragUpdateDetails d) {
    if (!_canReply) return;
    _swipe.stop();
    final next = (_dragX + d.delta.dx).clamp(-_swipeMax, 0.0);
    final armed = next <= -_swipeTrigger;
    // Fires as the threshold is crossed in either direction, so the finger is
    // told what a release would do while it can still change its mind.
    if (armed != _armed) HapticFeedback.selectionClick();
    setState(() {
      _dragX = next;
      _armed = armed;
    });
  }

  void _onSwipeEnd() {
    if (!_canReply) return;
    if (_armed) {
      HapticFeedback.mediumImpact();
      _startReply();
    }
    _armed = false;
    _swipeFrom = _dragX;
    if (_swipeFrom != 0) _swipe.forward(from: 0);
  }

  /// Anything with words in it can be copied — including the caption on a
  /// photo. A voice note or a bare image has nothing to put on the clipboard.
  bool get _copyingRestricted =>
      ref
          .read(conversationSettingsControllerProvider)[widget.chatId]
          ?.copyingRestricted ??
      false;

  SharedContact? get _sharedContact => widget.message.kind == MessageKind.text
      ? SharedContact.tryParse(widget.message.text)
      : null;

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
    // Adding one is a choice worth learning from; taking one back is not, and
    // promoting an emoji you just removed would be the strip learning exactly
    // the wrong thing.
    if (!alreadyMine) {
      unawaited(
        ref.read(reactionEmojiControllerProvider.notifier).remember(emoji),
      );
      // Only on the way in. A burst celebrating a reaction being *withdrawn*
      // would be the animation saying the opposite of the action.
      setState(() => _burstEmoji = emoji);
      _burst.forward(from: 0);
    }
    ref.read(messagingServiceProvider).sendReaction(
          widget.chatId,
          widget.message.wireId!,
          emoji,
          add: !alreadyMine,
        );
  }

  /// The whole keyboard, for the reaction the strip doesn't carry.
  Future<void> _reactFromPicker() async {
    final emoji = await showEmojiPicker(context);
    if (emoji == null || !mounted || !_canReact) return;
    _toggleReaction(emoji);
  }

  /// Telegram-style long-press menu: a small popup anchored at the finger,
  /// floating above everything. A reaction strip on top (when the message can
  /// carry reactions), then the per-message actions.
  Future<void> _showActions(Offset at) async {
    final t = AppLocalizations.of(context);
    final pinnedHere = widget.message.wireId != null &&
        ref
            .read(pinnedControllerProvider.notifier)
            .isPinned(widget.chatId, widget.message.wireId!);
    final strip = ref.read(reactionEmojiControllerProvider);

    final picked = await showContextPopup<String>(
      context: context,
      globalPosition: at,
      items: [
        _detailsHeader(t),
        if (_canReact)
          PopupMenuItem<String>(
            enabled: false,
            padding: EdgeInsets.zero,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                // Five, not six: the picker button takes the sixth slot, and
                // the row is inside a popup menu that stops widening at 280
                // logical pixels. A seventh cell is where it starts clipping.
                for (final e in strip.take(5))
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
                // The way out of the six. Everything the system can draw is
                // behind it, and whatever is chosen there joins the strip — so
                // the row in front of you drifts toward the emoji you actually
                // use rather than staying the set that shipped.
                Builder(
                  builder: (ctx) => InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: () => Navigator.of(ctx).pop('r+'),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.add_reaction_outlined,
                        size: 22,
                        color: AppColors.textOnGlassDim,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (widget.message.wireId != null)
          _menuRow(
              'reply', Icons.reply, t.chatReplyAction, AppColors.textOnGlass),
        // A pin is conversation state, so it needs the shared transport id —
        // and either side may pin either side's message.
        if (widget.message.wireId != null)
          _menuRow(
            pinnedHere ? 'unpin' : 'pin',
            pinnedHere ? Icons.push_pin : Icons.push_pin_outlined,
            pinnedHere ? t.chatUnpinAction : t.chatPinAction,
            AppColors.textOnGlass,
          ),
        if (messageCanBeCopied(
          widget.message,
          copyingRestricted: _copyingRestricted,
        ))
          if (!_copyingRestricted)
            if (_canCopy)
              _menuRow('copy', Icons.copy_outlined, t.chatCopyAction,
                  AppColors.textOnGlass),
        if (messageCanBeForwarded(
          widget.message,
          copyingRestricted: _copyingRestricted,
        ))
          if (!_copyingRestricted)
            if (_canForward)
              _menuRow('forward', Icons.shortcut_outlined, t.chatForwardAction,
                  AppColors.textOnGlass),
        if (_canEdit)
          _menuRow('edit', Icons.edit_outlined, t.chatEditAction,
              AppColors.textOnGlass),
        _menuRow('select', Icons.checklist_rounded, t.chatSelectAction,
            AppColors.textOnGlass),
        _menuRow('delete', Icons.delete_outline, t.chatDeleteAction,
            AppColors.danger),
      ],
    );

    if (picked == null || !mounted) return;
    if (picked == 'r+') {
      await _reactFromPicker();
    } else if (picked.startsWith('r:')) {
      _toggleReaction(picked.substring(2));
    } else if (picked == 'reply') {
      _startReply();
    } else if (picked == 'copy') {
      await Clipboard.setData(ClipboardData(text: widget.message.text));
      if (!mounted) return;
      showCopiedToast(context, t.chatCopied);
    } else if (picked == 'pin' || picked == 'unpin') {
      await ref.read(messagingServiceProvider).sendPin(
            widget.chatId,
            widget.message.wireId!,
            pinned: picked == 'pin',
          );
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
    } else if (picked == 'select') {
      ref
          .read(messageSelectionProvider(widget.chatId).notifier)
          .start(widget.message.id);
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
    // Tappable: a quote names a message, and the thing anyone wants from it is
    // to see the message. Nothing to go to when the original is gone, so the
    // tap is withheld rather than bouncing off a toast.
    return GestureDetector(
      onTap: quoted == null
          ? null
          : () => ref
              .read(chatJumpRequestProvider(widget.chatId).notifier)
              .state = wireId,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        decoration: BoxDecoration(
          color: AppColors.glass(0.06),
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
      ),
    );
  }

  /// A one-line snippet of [m] for a reply preview / quote box.
  static String _replyPreview(Message m) {
    final contact = SharedContact.tryParse(m.text);
    if (contact != null) return contact.displayName;
    switch (m.kind) {
      case MessageKind.image:
        return '📷';
      case MessageKind.audio:
        return '🎤';
      case MessageKind.file:
        return '📎 ${m.fileName ?? ''}'.trimRight();
      case MessageKind.poll:
        return '📊 ${m.text}';
      case MessageKind.text:
        final t = m.text.replaceAll('\n', ' ').trim();
        return t.length > 80 ? '${t.substring(0, 80)}…' : t;
    }
  }

  /// Non-tappable first row of the long-press menu: when this message was sent
  /// and, for our own messages the peer has acknowledged, when they read it.
  ///
  /// This is where the read time lives rather than in the bubble: the bubble
  /// already carries a clock and a tick, and a second timestamp on every line
  /// would crowd the conversation for something you only look up occasionally.
  /// It works for a photo or a voice note exactly as it does for text — the
  /// long-press covers the whole bubble, and media now carries the wireId a
  /// receipt refers to.
  PopupMenuItem<String> _detailsHeader(AppLocalizations t) {
    final m = widget.message;
    final readAt = m.readAt;
    // In a channel the answer to "who has seen this" is a list, because there
    // is no roster to count against — only the people who said so. Newest last,
    // so the order matches the order they arrived in.
    final readers = m.readBy.entries.toList()
      ..sort((a, b) => a.value.at.compareTo(b.value.at));
    final lines = 1 + (readAt != null ? 1 : 0) + readers.length;
    return PopupMenuItem<String>(
      enabled: false,
      height: (18.0 * lines + 12).clamp(30.0, 220.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.chatSentAt(formatMessageDetailsTime(context, m.sentAt)),
            style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 11.5),
          ),
          if (readAt != null)
            Text(
              t.chatReadAt(formatMessageDetailsTime(context, readAt)),
              style: const TextStyle(
                color: _BubbleMeta._readColor,
                fontSize: 11.5,
              ),
            ),
          for (final r in readers)
            Text(
              '${r.value.name} · '
              '${formatMessageDetailsTime(context, r.value.at)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _BubbleMeta._readColor,
                fontSize: 11.5,
              ),
            ),
        ],
      ),
    );
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
    final chosen = await pickForwardTarget(context, ref, widget.chatId);
    if (chosen == null || !mounted) return;
    final t = AppLocalizations.of(context);
    await forwardTextTo(ref, chosen, widget.message.text);
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
          side: BorderSide(color: AppColors.glass(0.15)),
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
    final copyingRestricted = ref
            .watch(conversationSettingsControllerProvider)[widget.chatId]
            ?.copyingRestricted ??
        false;
    final sharedContact = _sharedContact;

    // Marked in the bubble too, not only in the banner up top: scrolling back
    // through history, you want to see which line the banner is pointing at.
    ref.watch(pinnedControllerProvider);
    final pinned = message.wireId != null &&
        ref
            .read(pinnedControllerProvider.notifier)
            .isPinned(widget.chatId, message.wireId!);

    // Set for a moment after a jump lands on this message — from a tapped
    // quote, the pinned bar, or a search result. Without it the screen simply
    // moves and nothing says which line you were sent to.
    final highlighted =
        ref.watch(chatHighlightProvider(widget.chatId)) == message.id;

    // While a selection is running the whole row becomes a checkbox: a tap
    // ticks instead of doing whatever that bubble's tap normally does (open a
    // photo, play a voice note), because a mode where some taps select and
    // others open is a mode nobody can predict.
    final selection = ref.watch(messageSelectionProvider(widget.chatId));
    final selecting = selection.isNotEmpty;
    final selected = selection.contains(message.id);

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
    // No BackdropFilter here, deliberately. Every bubble used to run its own
    // gaussian, which on a full screen of conversation is a dozen blur passes
    // per frame — the most expensive thing in the app, on its most-scrolled
    // screen. What it sampled was the aurora: four wide radial gradients.
    // Blurring a soft gradient returns the same soft gradient, so the passes
    // bought nothing visible (the same reasoning FloatingGlass.blur already
    // documents for the rows). The fill, border and shadows are unchanged.
    //
    // The RepaintBoundary stays: it keeps one bubble's repaint out of its
    // neighbours as the list scrolls.
    final bubble = RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: FloatingGlass.shadows,
        ),
        child: ClipRRect(
          borderRadius: radius,
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
                    border: Border.all(color: AppColors.glass(0.18)),
                  )
                : BoxDecoration(
                    color: AppColors.glass(0.10),
                    borderRadius: radius,
                    border: Border.all(color: AppColors.glass(0.16)),
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
                  _ImagePayload(
                    message: message,
                    chatId: widget.chatId,
                    onDoubleTap: _canReact ? _quickReact : null,
                  )
                else if (message.kind == MessageKind.audio)
                  VoiceBubble(message: message, chatId: widget.chatId)
                else if (message.kind == MessageKind.file)
                  // Restricted means "do not take this elsewhere", not "do not
                  // look at it". Wrapping the row in an IgnorePointer made a
                  // received file unopenable on the device it was sent to,
                  // which is not a privacy control — it is the file simply not
                  // working. The restriction belongs one level in, on the
                  // share-to-another-app fallback.
                  FileBubble(
                    message: message,
                    sharingRestricted: copyingRestricted,
                  )
                else if (message.kind == MessageKind.poll)
                  PollBubble(
                    message: message,
                    chatId: widget.chatId,
                  )
                else if (sharedContact != null)
                  _SharedContactBubble(
                    contact: sharedContact,
                    onTap: () => context.push(
                      '/person/' +
                          Uri.encodeComponent(sharedContact.pubkeyHex) +
                          '?name=' +
                          Uri.encodeQueryComponent(
                            sharedContact.displayName,
                          ),
                    ),
                  )
                else
                  MentionText(message.text),
                const SizedBox(height: 4),
                _BubbleMeta(message: message, pinned: pinned),
              ],
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
          // The jump marker is a band across the whole row, edge to edge, the
          // way Telegram does it — not a ring around the bubble. A ring is
          // read as a property of the message ("this one is special"); a band
          // is read as a place ("you were brought here"), which is what a
          // tapped quote, the pinned bar and a search hit all mean. It fades
          // in and back out on its own, so nothing is left marked.
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            color: selected
                ? AppColors.brandPrimary.withValues(alpha: 0.22)
                : highlighted
                    ? AppColors.brandPrimary.withValues(alpha: 0.16)
                    : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
            child: GestureDetector(
              // Horizontal only: a vertical drag stays with the list, so the
              // conversation scrolls exactly as before and the gesture arena
              // decides between them on direction rather than on timing.
              // Swiping to reply is off while selecting — the row means one
              // thing at a time.
              onHorizontalDragUpdate: selecting ? null : _onSwipeUpdate,
              onHorizontalDragEnd: selecting ? null : (_) => _onSwipeEnd(),
              onHorizontalDragCancel: selecting ? null : _onSwipeEnd,
              onTap: selecting
                  ? () => ref
                      .read(messageSelectionProvider(widget.chatId).notifier)
                      .toggle(message.id)
                  : null,
              child: Stack(
                children: [
                  Transform.translate(
                    offset: Offset(_dragX, 0),
                    child: Row(
                      mainAxisAlignment: mine
                          ? MainAxisAlignment.end
                          : MainAxisAlignment.start,
                      children: [
                        if (selecting) ...[
                          Icon(
                            selected
                                ? Icons.check_circle_rounded
                                : Icons.radio_button_unchecked_rounded,
                            size: 20,
                            color: selected
                                ? AppColors.brandPrimary
                                : AppColors.textOnGlassFaint,
                          ),
                          const SizedBox(width: 8),
                        ],
                        ConstrainedBox(
                          constraints: BoxConstraints(
                              maxWidth:
                                  MediaQuery.sizeOf(context).width * 0.75),
                          child: Column(
                            crossAxisAlignment: mine
                                ? CrossAxisAlignment.end
                                : CrossAxisAlignment.start,
                            children: [
                              // Inert while selecting, so a photo's own tap
                              // cannot win the arena and open the viewer when
                              // the row was meant to tick.
                              IgnorePointer(
                                ignoring: selecting,
                                child: GestureDetector(
                                  onLongPressStart: (d) =>
                                      _showActions(d.globalPosition),
                                  onDoubleTap: _canReact ? _quickReact : null,
                                  child: bubble,
                                ),
                              ),
                              if (message.reactions.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: _ReactionsRow(
                                    reactions: message.reactions,
                                    revisions: _reactionRev,
                                    fresh: _freshReactions,
                                    onTap: _canReact ? _toggleReaction : null,
                                  ),
                                ),
                              // Only under our own: "who has seen mine" is the
                              // question people ask. On someone else's it would
                              // put a counter under every line of the channel.
                              if (message.isMine && message.readBy.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: _ReadByChip(
                                    label: AppLocalizations.of(context)
                                        .chatReadByCount(message.readBy.length),
                                    onTapAt: _showActions,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_dragX < -1)
                    Positioned.fill(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _SwipeReplyHint(
                          progress: (_dragX.abs() / _swipeTrigger).clamp(0, 1),
                        ),
                      ),
                    ),
                  if (_burstEmoji != null)
                    // Fills the row rather than sizing to the emoji, so the
                    // painter has the bubble's own geometry to throw from — and
                    // `IgnorePointer` because a shower of confetti that eats
                    // the next tap would be worse than no shower at all.
                    Positioned.fill(
                      child: IgnorePointer(
                        child: _ReactionBurst(
                          emoji: _burstEmoji!,
                          progress: _burst,
                          fromRight: mine,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The arrow that arrives from the right edge as a bubble is dragged left,
/// telling the finger what releasing will do before it commits.
///
/// Fills in as the drag approaches the threshold and reaches full strength
/// exactly when the release would take, so "will this work?" is answered by
/// looking rather than by trying.
class _SharedContactBubble extends StatelessWidget {
  const _SharedContactBubble({
    required this.contact,
    required this.onTap,
  });

  final SharedContact contact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 210, maxWidth: 250),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              PeerAvatar(
                peerId: contact.pubkeyHex,
                label: contact.displayName,
                size: 46,
                online: false,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      t.profileContactCard,
                      style: TextStyle(
                        color: AppColors.textOnGlassDim,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      contact.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textOnGlass,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      t.contactProfileOpen,
                      style: TextStyle(
                        color: AppColors.textOnGlassDim,
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: AppColors.textOnGlassDim,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SwipeReplyHint extends StatelessWidget {
  const _SwipeReplyHint({required this.progress});

  /// 0 at rest, 1 once the drag would file a reply.
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: progress,
      child: Transform.scale(
        scale: 0.7 + 0.3 * progress,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.brandPrimary.withValues(alpha: 0.18 * progress),
            border: Border.all(
              color: AppColors.brandPrimary.withValues(alpha: 0.5 * progress),
            ),
          ),
          child: Icon(
            Icons.reply,
            size: 17,
            color: AppColors.brandPrimary,
          ),
        ),
      ),
    );
  }
}

/// Row of reaction chips shown under a bubble. Each chip is `emoji ×count`
/// (count hidden when 1); a chip the local user contributed to is tinted.
class _ReactionsRow extends StatelessWidget {
  const _ReactionsRow({
    required this.reactions,
    required this.revisions,
    required this.fresh,
    required this.onTap,
  });

  final Map<String, Set<String>> reactions;

  /// Bumped by the bubble for an emoji whose tally moved while it was on
  /// screen. The chip pops on the change, not on the value.
  final Map<String, int> revisions;

  /// Emoji that arrived on a bubble that was already on screen — the ones that
  /// should pop themselves into existence rather than simply being there.
  final Set<String> fresh;

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
              // Keyed on the emoji so element identity follows the *reaction*.
              // Unkeyed children of a Wrap are matched by position, so a chip
              // dropping out of the middle would hand its state — including a
              // half-played pop — to whichever emoji shifted into its slot.
              key: ValueKey(entry.key),
              emoji: entry.key,
              count: entry.value.length,
              mine: entry.value.contains('me'),
              revision: revisions[entry.key] ?? 0,
              fresh: fresh.contains(entry.key),
              onTap: onTap == null ? null : () => onTap!(entry.key),
            ),
      ],
    );
  }
}

/// "Read by N" under one of our own channel messages.
///
/// Deliberately just a count. The names and times are one tap away in the same
/// details popup that already answers "when was this sent / read", because a
/// channel with a dozen members would otherwise put a dozen names under every
/// line — and the count is what anyone glancing at the chat actually wants.
class _ReadByChip extends StatelessWidget {
  const _ReadByChip({required this.label, required this.onTapAt});

  final String label;

  /// Takes the tap's global position, because the details popup opens anchored
  /// to where it was tapped — same as a long-press on the bubble itself.
  final void Function(Offset) onTapAt;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (d) => onTapAt(d.globalPosition),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.glass(0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.glass(0.12)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.done_all,
              size: 12,
              color: _BubbleMeta._readColor,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                color: _BubbleMeta._readColor,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReactionChip extends StatelessWidget {
  const _ReactionChip({
    super.key,
    required this.emoji,
    required this.count,
    required this.mine,
    required this.revision,
    required this.fresh,
    required this.onTap,
  });

  final String emoji;
  final int count;
  final bool mine;

  /// Changes when the tally behind this chip moved. See [_ReactionsRow].
  final int revision;

  /// True when the chip is being built for the first time *because the reaction
  /// just landed*, as opposed to because the row scrolled back into view.
  final bool fresh;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return PopOnChange(
      value: revision,
      initialPop: fresh,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          // The tint is the whole feedback for "this one is mine", and it used
          // to arrive between two frames. 180 ms is enough to see the fill
          // travel without the chip feeling slow to answer a tap.
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: mine
                ? AppColors.brandPrimary.withValues(alpha: 0.22)
                : AppColors.glass(0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: mine
                  ? AppColors.brandPrimary.withValues(alpha: 0.6)
                  : AppColors.glass(0.14),
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
      ),
    );
  }
}

/// One spark of a [_ReactionBurst]: where it is thrown and how it tumbles.
class _Spark {
  const _Spark({
    required this.angle,
    required this.distance,
    required this.spin,
    required this.scale,
    required this.lead,
  });

  /// Radians, canvas convention — `-pi/2` is straight up.
  final double angle;
  final double distance;
  final double spin;
  final double scale;

  /// Fraction of the run this spark waits before it leaves. A handful of copies
  /// departing on the same frame reads as one object splitting; staggering them
  /// by a few hundredths reads as a handful being thrown.
  final double lead;
}

/// The shower of copies that follows a reaction being added.
///
/// Telegram's version is a Lottie sticker over a particle field. This is the
/// part of it that carries the feeling and none of the part that needs an
/// animation runtime: a few copies of the same emoji thrown up and outward,
/// tumbling, shrinking, pulled back down, gone in about six tenths of a second.
///
/// It is a [CustomPaint] driven straight off the controller rather than a widget
/// per particle, so a burst costs one repaint per frame and rebuilds nothing —
/// and it leaves the tree the moment it finishes, because the standing rule in
/// this app is that nothing animates while it has nothing to say.
class _ReactionBurst extends StatefulWidget {
  const _ReactionBurst({
    required this.emoji,
    required this.progress,
    required this.fromRight,
  });

  final String emoji;
  final Animation<double> progress;

  /// Our own bubble sits on the right, so that is where its reaction is thrown
  /// from. Aiming every burst at the centre would have half of them start
  /// nowhere near the message they belong to.
  final bool fromRight;

  @override
  State<_ReactionBurst> createState() => _ReactionBurstState();
}

class _ReactionBurstState extends State<_ReactionBurst> {
  /// Rolled once, here, and not inside `paint`.
  ///
  /// The bubble rebuilds for reasons that have nothing to do with this — a swipe
  /// in progress, a status tick landing — and a painter that draws dice would
  /// hand every spark a new trajectory mid-flight. State outlives those
  /// rebuilds; a new burst is a new element and gets a fresh throw.
  late final List<_Spark> _sparks = _throw();

  static List<_Spark> _throw() {
    final rand = math.Random();
    return [
      for (var i = 0; i < 7; i++)
        _Spark(
          // A wedge aimed up and outward. Straight up is a fountain and flat
          // out is an explosion; the ground between them is what reads as
          // thrown by hand.
          angle: -math.pi * (0.15 + 0.7 * rand.nextDouble()),
          distance: 40 + 32 * rand.nextDouble(),
          spin: (rand.nextDouble() - 0.5) * 1.7,
          scale: 0.62 + 0.5 * rand.nextDouble(),
          lead: 0.12 * rand.nextDouble(),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _ReactionBurstPainter(
          emoji: widget.emoji,
          progress: widget.progress,
          fromRight: widget.fromRight,
          sparks: _sparks,
        ),
      ),
    );
  }
}

class _ReactionBurstPainter extends CustomPainter {
  _ReactionBurstPainter({
    required this.emoji,
    required this.progress,
    required this.fromRight,
    required this.sparks,
  }) : super(repaint: progress);

  final String emoji;
  final Animation<double> progress;
  final bool fromRight;
  final List<_Spark> sparks;

  /// Laid out once per painter and reused for every spark on every frame. The
  /// glyph never changes during a burst; measuring it seven times a frame would
  /// be the most expensive thing here by a wide margin.
  late final TextPainter _glyph = TextPainter(
    text: TextSpan(text: emoji, style: const TextStyle(fontSize: 20)),
    textDirection: TextDirection.ltr,
  )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    if (t <= 0 || t >= 1) return;

    final origin = Offset(
      size.width * (fromRight ? 0.80 : 0.20),
      size.height * 0.5,
    );

    // One layer for the whole shower, not one per spark: they all fade
    // together, and seven saveLayers a frame is exactly the sort of cost that
    // turns into a dropped frame on a mid-range phone.
    final fade = t < 0.55 ? 1.0 : (1 - (t - 0.55) / 0.45).clamp(0.0, 1.0);
    canvas.saveLayer(
      Offset.zero & size,
      Paint()..color = Color.fromRGBO(0, 0, 0, fade),
    );

    for (final spark in sparks) {
      final local = ((t - spark.lead) / (1 - spark.lead)).clamp(0.0, 1.0);
      if (local == 0) continue;

      // Distance eases out — thrown hard, slowing — while the downward pull
      // grows with the square of the time, which is the only part of this that
      // has to look like physics for the rest to read as physics.
      final travelled = spark.distance * Curves.easeOutCubic.transform(local);
      final dx = math.cos(spark.angle) * travelled;
      final dy = math.sin(spark.angle) * travelled + 30 * local * local;

      final grow = local < 0.22 ? local / 0.22 : 1.0;
      final shrink = 1 - 0.5 * math.max(0.0, (local - 0.35) / 0.65);
      final scale = spark.scale * grow * shrink;
      if (scale <= 0) continue;

      canvas.save();
      canvas.translate(origin.dx + dx, origin.dy + dy);
      canvas.rotate(spark.spin * local);
      canvas.scale(scale);
      _glyph.paint(canvas, Offset(-_glyph.width / 2, -_glyph.height / 2));
      canvas.restore();
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_ReactionBurstPainter old) =>
      old.emoji != emoji ||
      old.fromRight != fromRight ||
      !identical(old.sparks, sparks);
}

/// In-bubble image rendering. While the bytes are still in flight (sender
/// hasn't finished chunking, or receiver hasn't reassembled), shows a
/// placeholder block with a spinner — the bubble still occupies space so
/// the list doesn't reflow when the image finally appears.
class _ImagePayload extends StatelessWidget {
  const _ImagePayload({
    required this.message,
    required this.chatId,
    this.onDoubleTap,
  });

  final Message message;
  final String chatId;

  /// Quick-reaction handler, handed down from the bubble.
  ///
  /// A photo owns its own tap (it opens the viewer), and a child's tap wins the
  /// arena outright — so without this the second tap of a double-tap would just
  /// open the gallery and the reaction would never fire. Registering both on the
  /// same detector lets Flutter hold the single tap until the double-tap window
  /// closes, which costs the viewer a barely perceptible delay and is what makes
  /// the gesture work on media at all.
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final path = message.imagePath;
    final fileExists = path != null && File(path).existsSync();

    // A view-once photo never renders as a thumbnail. The whole point is that
    // it is looked at deliberately, once — a picture you can scroll past twice
    // in the transcript has already been seen more than once.
    if (message.viewOnce) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220, maxHeight: 220),
        child: _ViewOncePayload(
          message: message,
          chatId: chatId,
          available: fileExists,
        ),
      );
    }

    final heroTag = 'image-${message.id}';
    final body = fileExists
        ? GestureDetector(
            onDoubleTap: onDoubleTap,
            onTap: () => Navigator.of(context).push(
              mediaRoute<void>(
                (_) => ChatMediaGalleryScreen(
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
                  // Decoded at the size it is drawn, not the size it was sent.
                  //
                  // Without this the bubble decodes the whole photo — the mesh
                  // encoder tops out around 1600 px, so that is a 1600×1600
                  // bitmap, ten megabytes of it, to fill a box 220 points
                  // wide. Every photo in the conversation, held in the image
                  // cache. Scrolling a chat with pictures in it then costs a
                  // full-resolution decode per photo and a texture upload to
                  // match, which is most of why such a chat warms the phone.
                  // At the drawn size it is a twenty-fifth of the pixels.
                  cacheWidth: (220 * MediaQuery.devicePixelRatioOf(context))
                      .round(),
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

/// Whether tapping a view-once bubble may open the photo.
///
/// Never for our own: a photo you sent is gone from here the moment it leaves,
/// the way Telegram treats one. It used to stay openable until the recipient's
/// ack came back, which read as "still mine for now" and was worse than it
/// sounds — the viewer fired the same "I have seen it" notice for it, so
/// glancing at what you sent destroyed the copy the other person had not
/// opened. There is nothing to look at anyway now: an outgoing view-once photo
/// is never written to this phone's disk.
///
/// [fileExists] is the received half — the bytes may still be arriving, or have
/// already been burned.
bool viewOnceCanBeOpened(Message message, {required bool fileExists}) =>
    !message.isMine && !message.viewOnceConsumed && fileExists;

/// The states a view-once photo can be in: waiting to be opened, spent, still
/// arriving, or one of ours that was sent.
///
/// Deliberately never the picture itself. Tapping opens
/// [ViewOnceMediaScreen] — not the swipeable gallery, which has Share and
/// Save buttons and would happily page from this photo to every other one in
/// the chat.
class _ViewOncePayload extends ConsumerWidget {
  const _ViewOncePayload({
    required this.message,
    required this.chatId,
    required this.available,
  });

  final Message message;
  final String chatId;
  final bool available;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final spent = message.viewOnceConsumed;
    final mine = message.isMine;
    final openable = viewOnceCanBeOpened(message, fileExists: available);

    return GestureDetector(
      onTap: openable
          ? () => Navigator.of(context).push(
                mediaRoute<void>(
                  (_) => ViewOnceMediaScreen(
                    chatId: chatId,
                    message: message,
                  ),
                ),
              )
          : null,
      child: Container(
        width: 200,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: AppColors.glass(spent ? 0.05 : 0.12),
          border: Border.all(
            color: spent
                ? AppColors.glass(0.10)
                : AppColors.brandPrimary.withValues(alpha: 0.35),
          ),
        ),
        // Centred as a group rather than left-aligned with the text filling
        // whatever is left: on two lines the old layout put the icon against
        // one edge and a ragged block of text against the other, which read as
        // a mistake rather than a label.
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              spent
                  ? Icons.visibility_off_outlined
                  : mine
                      ? Icons.done_rounded
                      : Icons.local_fire_department_outlined,
              size: 20,
              color: spent ? AppColors.textOnGlassFaint : AppColors.brandPrimary,
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                // Four states, and the one that is ours says only that it went.
                // "Opened" still lands on it afterwards, which is the one piece
                // of news the sender does want: they looked.
                spent
                    ? t.viewOnceOpened
                    : mine
                        ? t.viewOnceSent
                        : openable
                            ? t.viewOnceTapToView
                            : t.viewOnceUnavailable,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color:
                      spent ? AppColors.textOnGlassFaint : AppColors.textOnGlass,
                  fontSize: 13,
                  fontWeight: spent ? FontWeight.w400 : FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
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
        color: AppColors.glass(0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (spinning)
            SizedBox(
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
  const _BubbleMeta({required this.message, this.pinned = false});

  final Message message;

  /// True when this is the chat's pinned message.
  final bool pinned;

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
        if (pinned) ...[
          Icon(
            Icons.push_pin,
            size: 11,
            color: AppColors.ink(message.isMine ? 0.8 : 0.55),
            semanticLabel: t.chatPinnedTitle,
          ),
          const SizedBox(width: 4),
        ],
        if (message.forwardSecret) ...[
          Icon(
            Icons.lock_clock,
            size: 11,
            color: AppColors.ink(message.isMine ? 0.8 : 0.55),
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
              color: AppColors.ink(message.isMine ? 0.7 : 0.45),
            ),
          ),
          const SizedBox(width: 4),
        ],
        Text(
          time,
          style: TextStyle(
            fontSize: 10.5,
            color: AppColors.ink(message.isMine ? 0.8 : 0.5),
          ),
        ),
        if (message.isMine) ...[
          const SizedBox(width: 4),
          _StatusTick(status: message.status),
        ],
      ],
    );
  }
}

/// The delivery tick — clock, then one check, then two in blue.
///
/// It is the one state change in a conversation that everybody watches, and it
/// used to happen between two frames: the glyph was simply a different glyph on
/// the next build. That is invisible. The eye is told nothing happened, and
/// "read" — the moment the whole indicator exists for — lands without a sound.
///
/// [AnimatedSwitcher] rather than a controller of our own, for one specific
/// property: **it does not animate the child it is first built with.** A bubble
/// scrolled back into view shows its tick already settled instead of popping it
/// again, which is the same rule [PopOnChange] is built around and the reason
/// neither of them animates from `initState`. It also cross-fades the colour for
/// free, so the blue arrives with the second check rather than snapping ahead of
/// it.
class _StatusTick extends StatelessWidget {
  const _StatusTick({required this.status});

  final MessageStatus status;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      // One slot, right-aligned, rather than the default Stack that sizes
      // itself to hold every child at once. The ticks are not the same width —
      // one check against two — and the default would shove the timestamp
      // sideways and back for the length of the transition.
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.centerRight,
        children: [...previous, if (current != null) current],
      ),
      transitionBuilder: (child, animation) => FadeTransition(
        // Plain `animation` here and a curve only on the scale: `easeOutBack`
        // overshoots above 1 by design, which is what gives the tick its snap —
        // and what would trip Opacity's assert if it drove the fade too.
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.55, end: 1).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
          ),
          child: child,
        ),
      ),
      child: Icon(
        switch (status) {
          MessageStatus.sending => Icons.schedule,
          MessageStatus.delivered => Icons.done,
          MessageStatus.read => Icons.done_all,
          MessageStatus.failed => Icons.error_outline,
        },
        // The key is what makes this a transition at all: without it the
        // switcher sees one Icon being reconfigured and swaps the glyph
        // silently, exactly as before.
        key: ValueKey(status),
        size: 12,
        color: switch (status) {
          MessageStatus.failed => AppColors.danger,
          MessageStatus.read => _BubbleMeta._readColor,
          _ => AppColors.ink(0.85),
        },
        semanticLabel: switch (status) {
          MessageStatus.sending => t.chatSending,
          MessageStatus.delivered => t.chatDelivered,
          MessageStatus.read => t.chatRead,
          MessageStatus.failed => '!',
        },
      ),
    );
  }
}
