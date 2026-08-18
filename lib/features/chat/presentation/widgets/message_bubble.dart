import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:go_router/go_router.dart';
import '../../../../core/routing/back_gesture.dart';
import '../../../../core/routing/page_transitions.dart';
import '../../../../core/identity/nickname_controller.dart';
import '../../../../core/theme/colors.dart';
import '../../../../core/transport/messaging_service.dart';
import '../../../../core/theme/typography.dart';
import '../../../../core/util/debug_log.dart';
import '../../../../core/transport/shared_contact.dart';
import '../../../../core/transport/shared_location.dart';
import '../../../../core/utils/time_format.dart';
import '../../../../core/widgets/floating_glass.dart';
import '../../../../core/widgets/glass_toast.dart';
import '../../../peers/presentation/widgets/peer_avatar.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../chats/models/chat.dart';
import '../../../chats/presentation/chats_list_screen.dart' show chatsProvider;
import '../../data/chat_navigation.dart';
import '../../data/media_send_progress.dart';
import '../../data/message_selection.dart';
import '../../data/conversation_settings_controller.dart';
import '../../data/message_edit_target.dart';
import '../../data/message_reply_target.dart';
import '../../data/messages_controller.dart';
import '../../domain/message_preview.dart';
import '../../data/pinned_controller.dart';
import '../../data/reaction_emoji_controller.dart';
import '../../../map/data/map_friend_link.dart';
import '../../../channels/data/channel_roster_controller.dart';
import '../../../map/data/map_friends_controller.dart';
import '../../../map/data/map_presence_controller.dart';
import '../../../profile/data/privacy_settings_controller.dart';
import '../../../chats/data/saved_messages.dart';
import '../../../chats/data/saved_tags_controller.dart';
import 'emoji_picker_sheet.dart';
import 'message_spotlight.dart';
import '../../models/message.dart';
import '../chat_media_gallery_screen.dart';
import '../view_once_media_screen.dart';
import '../../../../core/util/media_storage.dart';
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
/// The words in a message, or null when it has none.
///
/// Not [Message.text], which is only words for a text message: a photo keeps
/// its mime type there and a sticker keeps its marker, so "copy" on a picture
/// put `image/jpeg` on the clipboard. A photo's words are its caption, and most
/// photos have none.
String? copyableText(Message message) {
  final words = switch (message.kind) {
    MessageKind.image => message.imageCaption,
    MessageKind.text => message.text,
    MessageKind.audio || MessageKind.file || MessageKind.poll => null,
  };
  final trimmed = words?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

bool messageCanBeCopied(
  Message message, {
  required bool copyingRestricted,
}) =>
    // A view-once photo is excluded even though its *caption* is text. The
    // bytes never leave either way, but offering Copy and Forward on something
    // the app has just promised to destroy reads as the promise not being
    // meant.
    !copyingRestricted &&
    !message.viewOnce &&
    copyableText(message) != null;

/// A picture can be passed on as well as a line of text.
///
/// It could not before, and the reason was an implementation detail wearing the
/// clothes of a rule: forwarding re-sends under our own identity, the text path
/// had a re-send and the media path did not, so "forward" quietly meant "if it
/// is words". Sending a photo on is the commonest forward there is — the bytes
/// are already on this phone, and [forwardMessageTo] reads them and sends them
/// the way the gallery does.
///
/// View-once is still excluded, for the reason above: the promise is that it
/// exists once.
bool messageCanBeForwarded(
  Message message, {
  required bool copyingRestricted,
}) {
  if (copyingRestricted || message.viewOnce) return false;
  return switch (message.kind) {
    MessageKind.image => MediaPaths.existsOrNull(message.imagePath),
    MessageKind.text => message.text.trim().isNotEmpty,
    // A voice note, a file and a poll are each their own send with their own
    // arguments; nothing is stopping them but nobody has asked yet.
    MessageKind.audio || MessageKind.file || MessageKind.poll => false,
  };
}

const double _swipeTrigger = 56;
const double _swipeMax = 76;

/// How wide a photo is drawn in a bubble.
///
/// It used to be a flat 220 points, which on a modern phone is a third of the
/// screen — a picture sent to be looked at, shown as a stamp, with the bubble's
/// own width unused around it. A share of the screen instead, clamped so it
/// stays inside the 75% the bubble itself is allowed and so a small phone does
/// not end up with something smaller than the old fixed size.
double photoBubbleWidth(BuildContext context) =>
    (MediaQuery.sizeOf(context).width * 0.68).clamp(220.0, 300.0);

/// A sticker is a gesture, not content: it keeps a size of its own, and a
/// larger one stops being an aside and starts being an announcement.
const double kStickerWidth = 158;

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
                                : Icons.person_outline_rounded,
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

/// Pass [message] on to [target], whatever it is made of.
///
/// A fresh send under our own identity, not a relay of the original frame:
/// the original is encrypted to a session the new chat has no key for, so it
/// could not be passed along even if we wanted it to be. For a picture that
/// means reading the bytes back off this phone and sending them the way the
/// gallery does — caption and sticker marker included, so a forwarded sticker
/// arrives as a sticker rather than as a photo of one.
Future<void> forwardMessageTo(WidgetRef ref, Chat target, Message message) async {
  if (message.kind == MessageKind.image) {
    final path = MediaPaths.repairOrNull(message.imagePath);
    if (path == null || !MediaPaths.exists(path)) return;
    final bytes = await File(path).readAsBytes();
    await ref.read(messagingServiceProvider).sendImage(
          target.id,
          bytes: bytes,
          mime: message.imageMime ?? 'image/jpeg',
          cachedPath: path,
          caption: message.isSticker
              ? Message.stickerMarkerFor(message.stickerEmoji)
              : message.imageCaption,
        );
    return;
  }
  await forwardTextTo(ref, target, message.text);
}

class MessageBubble extends ConsumerStatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.chatId,
    this.album,
    this.animateEntry = false,
  });

  final Message message;

  /// The chat this bubble lives in (pubkey-hex peer id or `#channel`). Needed
  /// to route a reaction back over the wire.
  final String chatId;

  /// Every photo of the batch this message opens, [message] included, or null
  /// for a picture that arrived on its own.
  ///
  /// The bubble stays one message's bubble — its timestamp, ticks, reactions,
  /// reply and menu are still [message]'s. Only the payload becomes the grid,
  /// which is what keeps a batch of nine photos from being nine bubbles. The
  /// grouping itself is `groupPhotoAlbums`, in the chat data layer.
  final List<Message>? album;

  /// True only for a message the local user has just sent. Old rows should not
  /// replay their entrance every time a virtualized list rebuilds them.
  final bool animateEntry;

  @override
  ConsumerState<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends ConsumerState<MessageBubble>
    with TickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
    value: widget.animateEntry ? 0 : 1,
  );

  /// Drives the spring back to rest after a swipe-to-reply, whether or not the
  /// gesture crossed the threshold.
  late final AnimationController _swipe = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(() {
      if (_swipeFrom == 0) return;
      _dragX.value =
          _swipeFrom * (1 - Curves.easeOutCubic.transform(_swipe.value));
    });

  /// Current horizontal offset of the bubble; never positive (this gesture only
  /// goes left) and never past [_swipeMax].
  ///
  /// A notifier rather than a field, and moved with `.value` rather than
  /// `setState`, because of what sits underneath it. Rebuilding this widget
  /// rebuilds the whole bubble � the photo, the caption, the reaction row, the
  /// read-by chip, every `MediaQuery` and localization lookup in the subtree �
  /// and the offset was being changed twice per gesture at frame rate: once per
  /// pointer move while the finger drags, then again on every tick of the
  /// spring coming home. On a 120 Hz screen that was the entire bubble rebuilt
  /// a hundred times a second to move it sideways by a few pixels, which is
  /// what made the swipe tear.
  ///
  /// The subtree is now built once and handed to [ValueListenableBuilder] as
  /// `child`, so a frame of this gesture costs one `Transform.translate` and
  /// nothing else. The animation is unchanged � same curve, same duration, same
  /// distance; only the per-frame bill for it is gone.
  final ValueNotifier<double> _dragX = ValueNotifier<double>(0);

  /// Where the spring started, so the animation can interpolate home.
  double _swipeFrom = 0;

  /// True once the drag is far enough that releasing would file a reply. Held
  /// separately from the offset so crossing the line can fire its own haptic
  /// exactly once.
  bool _armed = false;

  late final Animation<double> _scale = Tween<double>(
    begin: widget.animateEntry ? 0.96 : 1,
    end: 1,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));
  late final Animation<double> _fade = Tween<double>(
    begin: widget.animateEntry ? 0 : 1,
    end: 1,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: widget.animateEntry
        ? Offset(widget.message.isMine ? 0.06 : -0.04, 0.18)
        : Offset.zero,
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    if (widget.animateEntry) _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    _swipe.dispose();
    _dragX.dispose();
    super.dispose();
  }

  bool get _canReact => widget.message.wireId != null;

  /// Open the person a card names — importing them first when the card is an
  /// invitation carrying the whole signed announcement.
  ///
  /// An invitation from a room is the one case where the profile would
  /// otherwise open on somebody the app knows nothing about: no prekey, no
  /// relay identity, nothing to send to. Importing is exactly what the QR
  /// scanner does with the same card, and it is what turns "a name from a
  /// channel" into a contact who can be written to.
  Future<void> _openSharedContact(SharedContact contact) async {
    final card = contact.card;
    if (card != null) {
      try {
        await ref.read(messagingServiceProvider).addContactFromCard(card);
      } catch (e) {
        // Already known, or our own card offered back to us. Neither is worth
        // stopping the tap over — the profile below is still the right place
        // to land.
        debugPrint('contact invitation import: $e');
      }
    }
    if (!mounted) return;
    context.push(
      '/person/${Uri.encodeComponent(contact.pubkeyHex)}'
      '?name=${Uri.encodeQueryComponent(contact.displayName)}',
    );
  }

  /// The words under the picture, or under the whole batch of them.
  ///
  /// A batch carries its caption on the first photo, which is where it was
  /// drawn — as if it described that one picture. Any member's caption is the
  /// album's, because there is only ever one.
  String? get _caption {
    final album = widget.album;
    if (album == null) return widget.message.imageCaption;
    for (final message in album) {
      final caption = message.imageCaption;
      if (caption != null) return caption;
    }
    return null;
  }

  /// A reply needs the transport id everyone else filed the message under, and
  /// somewhere to compose it � the composer only builds reply frames in 1:1,
  /// so offering the gesture in a channel would swallow it silently.
  bool get _canReply =>
      widget.message.wireId != null && !widget.chatId.startsWith('#');

  void _startReply() {
    final m = widget.message;
    ref.read(messageReplyTargetProvider.notifier).state = MessageReplyTarget(
      chatId: widget.chatId,
      wireId: m.wireId!,
      preview: _replyPreview(m, AppLocalizations.of(context)),
      mine: m.isMine,
      authorName: m.authorName,
    );
  }

  /// Double-tap: the one-gesture path to the reaction people actually use �
  /// which is now the last one *they* used, not a constant in this file.
  void _quickReact() {
    if (!_canReact) return;
    HapticFeedback.lightImpact();
    _toggleReaction(
      ref.read(reactionEmojiControllerProvider.notifier).quickReaction,
    );
  }

  /// Logged once per bubble, so a conversation that will not swipe says why in
  /// the diagnostics log instead of only in the reporter's description.
  ///
  /// Reading the code has not been enough: the gate is `wireId != null` and not
  /// a channel, both look right, and the id is both persisted and restored — so
  /// the next report needs to carry which half is false rather than another
  /// round of guessing.
  bool _swipeRefusalLogged = false;

  void _onSwipeUpdate(DragUpdateDetails d) {
    if (!_canReply) {
      if (!_swipeRefusalLogged) {
        _swipeRefusalLogged = true;
        DebugLog.instance.log(
          'REPLY',
          'swipe ignored: wireId=${widget.message.wireId == null ? 'null' : 'set'}'
              ' channel=${widget.chatId.startsWith('#')}'
              ' kind=${widget.message.kind.name}',
        );
      }
      return;
    }
    _swipe.stop();
    final next = (_dragX.value + d.delta.dx).clamp(-_swipeMax, 0.0);
    final armed = next <= -_swipeTrigger;
    // Fires as the threshold is crossed in either direction, so the finger is
    // told what a release would do while it can still change its mind.
    if (armed != _armed) HapticFeedback.selectionClick();
    // No setState: _armed is haptics-only and never read in build, and the
    // offset drives the transform through its own notifier.
    _dragX.value = next;
    _armed = armed;
  }

  void _onSwipeEnd() {
    if (!_canReply) return;
    if (_armed) {
      HapticFeedback.mediumImpact();
      _startReply();
    }
    _armed = false;
    _swipeFrom = _dragX.value;
    if (_swipeFrom != 0) _swipe.forward(from: 0);
  }

  /// Anything with words in it can be copied � including the caption on a
  /// photo. A voice note or a bare image has nothing to put on the clipboard.
  bool get _copyingRestricted =>
      ref
          .read(conversationSettingsControllerProvider)[widget.chatId]
          ?.copyingRestricted ??
      false;

  SharedContact? get _sharedContact => widget.message.kind == MessageKind.text
      ? SharedContact.tryParse(widget.message.text)
      : null;

  /// A position rides inside a text message � see [SharedLocation] for why �
  /// so it is recognised the same way a shared contact is.
  SharedLocation? get _sharedLocation => widget.message.kind == MessageKind.text
      ? SharedLocation.tryParse(widget.message.text)
      : null;

  MapFriendLink? get _mapFriendLink => widget.message.kind == MessageKind.text
      ? MapFriendLink.tryParse(widget.message.text)
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

  /// Hold a message and everything else steps back.
  ///
  /// This was a popup menu anchored at the finger, which answered "what can I
  /// do to this?" while the conversation carried on behind it at full contrast
  /// — so the message the menu was about was one of thirty similar objects on
  /// screen, and the reaction strip along the top of it was a row of emoji
  /// floating over somebody else's sentence. See [showMessageSpotlight]: the
  /// room blurs, the message stays lit where it already is, and the choices
  /// arrange themselves around it.
  ///
  /// The vocabulary it answers in is unchanged — `r:<emoji>`, `r+`, or an
  /// action id — so everything below this call is the same code it always was.
  Future<void> _showActions(Offset at) async {
    final t = AppLocalizations.of(context);
    final pinnedHere = widget.message.wireId != null &&
        ref
            .read(pinnedControllerProvider.notifier)
            .isPinned(widget.chatId, widget.message.wireId!);
    final strip = ref.read(reactionEmojiControllerProvider);

    // Where this row actually sits, so the lit copy lands exactly on top of the
    // real one. Falls back to the press point if the render object has gone,
    // which puts the menu at the finger — the old behaviour, and a reasonable
    // last resort.
    final box = context.findRenderObject() as RenderBox?;
    final anchor = box != null && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : at & const Size(1, 1);

    final picked = await showMessageSpotlight(
      context: context,
      anchor: anchor,
      mine: widget.message.isMine,
      // The same widget from the same message, built again and made inert. A
      // snapshot would be a frame of nothing between the press and the menu,
      // and a screenful of pixels held for every long press.
      bubble: MessageBubble(
        message: widget.message,
        chatId: widget.chatId,
        album: widget.album,
      ),
      details: _detailsLines(t),
      // Six here, not five: the strip is its own bar now rather than a row
      // squeezed into a 280-point menu, so the picker button no longer costs a
      // slot.
      reactions: _canReact ? strip.take(6).toList() : const <String>[],
      actions: [
        // First. Selecting is how you act on more than one message, so it is
        // the entry to every bulk action in the chat — and buried between Edit
        // and Delete it read as a rarely-wanted setting.
        SpotlightAction(
          id: 'select',
          icon: Icons.checklist_rounded,
          label: t.chatSelectAction,
        ),
        if (widget.message.wireId != null)
          SpotlightAction(
            id: 'reply',
            icon: Icons.reply_rounded,
            label: t.chatReplyAction,
          ),
        // A pin is conversation state, so it needs the shared transport id —
        // and either side may pin either side's message.
        if (widget.message.wireId != null)
          SpotlightAction(
            id: pinnedHere ? 'unpin' : 'pin',
            icon: Icons.push_pin_rounded,
            label: pinnedHere ? t.chatUnpinAction : t.chatPinAction,
          ),
        if (messageCanBeCopied(
              widget.message,
              copyingRestricted: _copyingRestricted,
            ) &&
            !_copyingRestricted &&
            _canCopy)
          SpotlightAction(
            id: 'copy',
            icon: Icons.copy_rounded,
            label: t.chatCopyAction,
          ),
        if (messageCanBeForwarded(
              widget.message,
              copyingRestricted: _copyingRestricted,
            ) &&
            !_copyingRestricted &&
            _canForward)
          SpotlightAction(
            id: 'forward',
            icon: Icons.shortcut_rounded,
            label: t.chatForwardAction,
          ),
        if (_canEdit)
          SpotlightAction(
            id: 'edit',
            icon: Icons.edit_rounded,
            label: t.chatEditAction,
          ),
        // Saved-chat only: a tag is a way back to a note in a growing pile,
        // and there is no pile to file in a real conversation. Says "remove"
        // when one is already on, so the same entry both sets and clears.
        if (isSavedChat(widget.chatId))
          SpotlightAction(
            id: 'tag',
            icon: Icons.sell_rounded,
            label: ref.read(savedTagsProvider)[widget.message.id] == null
                ? _savedTagText(uk: 'Тег', en: 'Tag')
                : _savedTagText(uk: 'Прибрати тег', en: 'Remove tag'),
          ),
        SpotlightAction(
          id: 'delete',
          icon: Icons.delete_outline_rounded,
          label: t.chatDeleteAction,
          tone: AppColors.danger,
        ),
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
      await Clipboard.setData(
        ClipboardData(text: copyableText(widget.message) ?? ''),
      );
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
    } else if (picked == 'tag') {
      await _tagSavedMessage();
    } else if (picked == 'delete') {
      await _promptDelete();
    }
  }

  /// Put an emoji tag on this saved note, or clear the one it has.
  ///
  /// Already tagged: one tap here takes it off, no picker — removing a tag is
  /// the common half of managing them and should not cost a sheet. Untagged:
  /// the same emoji picker the quick-reaction setting uses.
  Future<void> _tagSavedMessage() async {
    final tags = ref.read(savedTagsProvider.notifier);
    if (tags.tagFor(widget.message.id) != null) {
      await tags.setTag(widget.message.id, null);
      return;
    }
    final emoji = await showEmojiPicker(context);
    if (emoji == null || !mounted) return;
    await tags.setTag(widget.message.id, emoji);
  }

  String _savedTagText({required String uk, required String en}) =>
      Localizations.localeOf(context).languageCode == 'uk' ? uk : en;

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
    // What the reply was written against, if we wrote it: kept on the message
    // so the box says something even when the original cannot be found. It
    // could not be found rather often — a cleared history, a message filed
    // under a different id, one that has not arrived yet — and every one of
    // those drew a bare "…". Replying to a sticker drew it every time.
    //
    // The lookup still comes first, because it is live: an edited message
    // should quote as it reads now, not as it read when it was answered.
    final preview = quoted != null
        ? _replyPreview(quoted, AppLocalizations.of(context))
        : (widget.message.replyPreview ?? '…');
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
  ///
  /// The same line the chat list and a notification show — one description of
  /// a message per app, not one per screen. A shared contact and a map link
  /// are the two things a quote can say more about than a list can: they are
  /// text on the wire, and the name inside them is the useful part.
  static String _replyPreview(Message m, AppLocalizations t) {
    final contact = SharedContact.tryParse(m.text);
    if (contact != null) return contact.displayName;
    final mapLink = MapFriendLink.tryParse(m.text);
    if (mapLink != null) return mapLink.displayName;
    final preview = messagePreview(m, t).replaceAll('\n', ' ').trim();
    return preview.length > 80 ? '${preview.substring(0, 80)}…' : preview;
  }

  /// Non-tappable first row of the long-press menu: when this message was sent
  /// and, for our own messages the peer has acknowledged, when they read it.
  ///
  /// This is where the read time lives rather than in the bubble: the bubble
  /// already carries a clock and a tick, and a second timestamp on every line
  /// would crowd the conversation for something you only look up occasionally.
  /// It works for a photo or a voice note exactly as it does for text � the
  /// long-press covers the whole bubble, and media now carries the wireId a
  /// receipt refers to.
  Widget _detailsLines(AppLocalizations t) {
    final m = widget.message;
    final readAt = m.readAt;
    // In a channel the answer to "who has seen this" is a list, because there
    // is no roster to count against � only the people who said so. Newest last,
    // so the order matches the order they arrived in.
    final readers = m.readBy.entries.toList()
      ..sort((a, b) => a.value.at.compareTo(b.value.at));
    return Column(
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
              '${r.value.name} � '
              '${formatMessageDetailsTime(context, r.value.at)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _BubbleMeta._readColor,
                fontSize: 11.5,
              ),
            ),
        ],
      );
  }

  /// Pick a chat and re-send this message's text into it.
  ///
  /// Forwarding is a fresh send, not a relay of the original frame: the text
  /// goes out under our own identity, signed and sealed for the new recipient.
  /// That is the only shape that works here � the original is encrypted to a
  /// session the new chat has no key for, so it could not be passed along even
  /// if we wanted to.
  Future<void> _promptForward() async {
    final chosen = await pickForwardTarget(context, ref, widget.chatId);
    if (chosen == null || !mounted) return;
    final t = AppLocalizations.of(context);
    await forwardMessageTo(ref, chosen, widget.message);
    if (!mounted) return;
    showGlassToast(
      context,
      t.chatForwardSent(chosen.peerName),
      icon: Icons.shortcut_rounded,
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
      // Its tag goes with it, so a deleted note leaves no orphan in the filter
      // bar matching nothing.
      if (isSavedChat(widget.chatId)) {
        unawaited(ref.read(savedTagsProvider.notifier).forget(m.id));
      }
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
    final sharedLocation = _sharedLocation;
    final mapFriendLink = _mapFriendLink;
    final activeMapFriends = ref.watch(mapFriendsControllerProvider);

    // Marked in the bubble too, not only in the banner up top: scrolling back
    // through history, you want to see which line the banner is pointing at.
    ref.watch(pinnedControllerProvider);
    final pinned = message.wireId != null &&
        ref
            .read(pinnedControllerProvider.notifier)
            .isPinned(widget.chatId, message.wireId!);

    // Set for a moment after a jump lands on this message � from a tapped
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
    // list and the nav bar use � nothing welded behind it, just a pane over the
    // aurora. It can't be a FloatingGlass (that surface is deliberately neutral
    // and these have to stay colour-coded by sender), so it wears the shared
    // shadow recipe over its own fill.
    //
    // No BackdropFilter here, deliberately. Every bubble used to run its own
    // gaussian, which on a full screen of conversation is a dozen blur passes
    // per frame � the most expensive thing in the app, on its most-scrolled
    // screen. What it sampled was the aurora: four wide radial gradients.
    // Blurring a soft gradient returns the same soft gradient, so the passes
    // bought nothing visible (the same reasoning FloatingGlass.blur already
    // documents for the rows). The fill, border and shadows are unchanged.
    //
    // The RepaintBoundary stays: it keeps one bubble's repaint out of its
    // neighbours as the list scrolls.
    // A sticker has no bubble at all: no fill, no border, no shadow. It is a
    // picture with a transparent background, and any of those would draw a
    // rectangle around something whose whole point is not having one.
    final sticker = message.isSticker;

    // Drawn edge to edge, so the rows around it put their own inset back.
    final photo = message.kind == MessageKind.image;
    const inset = EdgeInsets.symmetric(horizontal: 14, vertical: 10);
    Widget inBubble(Widget child) =>
        photo ? Padding(padding: inset, child: child) : child;

    final reacted = message.reactions.values.any((by) => by.isNotEmpty);
    // The clock rides *on* a picture that has nothing else to say — the way
    // every messenger draws one. A strip of bubble under the photo carrying
    // four characters is the frame this design spent a release removing, put
    // back one edge at a time. As soon as there is something else on that line
    // (a caption, a reaction) the row comes back and the clock joins it.
    final metaOnMedia = photo && !reacted && _caption == null;
    final meta = _BubbleMeta(
      message: message,
      pinned: pinned,
      onMedia: metaOnMedia,
      // Only in the saved chat does a tag exist, so only there is the map read.
      tag: isSavedChat(widget.chatId)
          ? ref.watch(savedTagsProvider)[message.id]
          : null,
    );

    final bubble = RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: sticker ? const <BoxShadow>[] : FloatingGlass.shadows,
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Container(
            // A photo fills its bubble; everything else sits inside padding.
            //
            // A picture framed by fourteen points of tinted glass on every side
            // reads as a picture *of* a message. Letting it run to the rounded
            // corners is what every messenger does, and it also buys back the
            // width: the same photo is drawn larger without the bubble growing.
            // The rows that keep their inset — an author's name, the caption,
            // the time — ask for it themselves below.
            padding: photo
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            // And no border on a photo bubble, which is why its corners looked
            // broken. `Border.all` paints its stroke *inside* the container, so
            // the picture sits a pixel in from it and is then clipped by the
            // ClipRRect at the outer radius: the stroke reads cleanly along the
            // straight edges and comes apart in every corner. That is the
            // "обводка плохо сделано, углов нету" in the report.
            //
            // Telegram draws no frame around a photo at all, and the reason
            // carries over — a border exists to give a pane of glass an edge,
            // and a picture already has one. Everything that is not a photo
            // keeps its border.
            decoration: sticker
                ? const BoxDecoration()
                : mine
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
                        // No frame around a photo — see the note by `padding`.
                        border: photo
                            ? null
                            : Border.all(color: AppColors.glass(0.18)),
                      )
                    : BoxDecoration(
                        color: AppColors.glass(0.10),
                        borderRadius: radius,
                        border: photo
                            ? null
                            : Border.all(color: AppColors.glass(0.16)),
                      ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Channel messages from others: show the author's name on top,
                // since a channel mixes many senders in one conversation.
                if (!mine && message.authorName != null) ...[
                  inBubble(
                    Text(
                      message.authorName!,
                      style: TextStyle(
                        color: AppColors.brandPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (!photo) const SizedBox(height: 2),
                ],
                if (message.replyToWireId != null)
                  inBubble(_quotedBox(message.replyToWireId!)),
                if (message.kind == MessageKind.image) ...[
                  // The picture, with the clock floating in its bottom corner
                  // when the bubble has no other line to put it on.
                  Stack(
                    children: [
                      if (widget.album case final album?)
                        _AlbumPayload(
                          messages: album,
                          chatId: widget.chatId,
                          onDoubleTap: _canReact ? _quickReact : null,
                        )
                      else
                        _ImagePayload(
                          message: message,
                          chatId: widget.chatId,
                          onDoubleTap: _canReact ? _quickReact : null,
                        ),
                      if (metaOnMedia)
                        Positioned(
                          right: 8,
                          bottom: 8,
                          // Inert, so the pill cannot swallow the tap that
                          // opens the photo underneath it.
                          child: IgnorePointer(child: _MetaPill(child: meta)),
                        ),
                      // How far the upload has got. Only on our own pictures
                      // and only while they are still going: a photo over
                      // Bluetooth is a few hundred chunks and minutes of them,
                      // and "sending" for all of it could not be told apart
                      // from a transfer that had stalled.
                      if (message.isMine &&
                          message.status == MessageStatus.sending)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: _SendProgressRing(messageId: message.id),
                          ),
                        ),
                    ],
                  ),
                  // The caption, which used to go missing entirely. It rides in
                  // `text`, and the chain below renders `text` only for a
                  // message that matched none of these branches � so a photo
                  // took the image branch and its caption was never drawn,
                  // however carefully it had been typed and delivered.
                  // One caption for the set. It is sent on the first photo of a
                  // batch, which is where it used to be drawn — reading as a
                  // remark about that one picture rather than about the lot.
                  if (_caption case final caption?)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: widget.album == null
                              ? photoBubbleWidth(context)
                              : _kAlbumWidth,
                        ),
                        child: MentionText(caption),
                      ),
                    ),
                ] else if (message.kind == MessageKind.audio)
                  VoiceBubble(message: message, chatId: widget.chatId)
                else if (message.kind == MessageKind.file)
                  // Restricted means "do not take this elsewhere", not "do not
                  // look at it". Wrapping the row in an IgnorePointer made a
                  // received file unopenable on the device it was sent to,
                  // which is not a privacy control � it is the file simply not
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
                else if (mapFriendLink != null &&
                    !widget.chatId.startsWith('#'))
                  _MapFriendLinkBubble(
                    link: mapFriendLink,
                    active: activeMapFriends.contains(widget.chatId),
                    mine: message.isMine,
                    onTap: () async {
                      if (mapFriendLink.kind == MapFriendLinkKind.invite &&
                          !message.isMine &&
                          !activeMapFriends.contains(widget.chatId)) {
                        await ref
                            .read(mapFriendsControllerProvider.notifier)
                            .activate(widget.chatId);
                        // Accepting *is* agreeing to be on the map, so the
                        // switch that decides whether a beacon is ever sent is
                        // turned on here. It defaults to off, and leaving it
                        // that way made accepting look like it had worked —
                        // the pairing was real, the pin never came, and the
                        // only cure was finding a toggle in Privacy nobody
                        // knew to look for.
                        await ref
                            .read(privacySettingsProvider.notifier)
                            .setShareMapLocation(true);
                        await ref.read(messagingServiceProvider).sendText(
                              widget.chatId,
                              MapFriendLink.accepted(
                                displayName:
                                    ref.read(nicknameControllerProvider),
                              ).encode(),
                            );
                        await ref
                            .read(mapPresenceControllerProvider.notifier)
                            .pokeNow();
                      }
                      if (!context.mounted) return;
                      context.go('/map');
                    },
                  )
                else if (sharedLocation != null)
                  _SharedLocationBubble(location: sharedLocation)
                else if (sharedContact != null)
                  _SharedContactBubble(
                    contact: sharedContact,
                    onTap: () => _openSharedContact(sharedContact),
                  )
                else
                  MentionText(message.text),
                if (!metaOnMedia) ...[
                  if (!photo) const SizedBox(height: 4),
                  // Reactions and the clock on one line, inside the bubble.
                  //
                  // They used to be a second row hanging *below* the bubble,
                  // which is a shape no messenger draws: it detached the
                  // reaction from the thing reacted to, pushed the next message
                  // down by a whole row, and left the bubble's own bottom line
                  // carrying nothing but four characters of time. One line, the
                  // reaction where it was put and the clock where it always is.
                  inBubble(
                    _BubbleFooter(
                      reactions: reacted
                          ? _ReactionsRow(
                              reactions: message.reactions,
                              onTap: _canReact ? _toggleReaction : null,
                            )
                          : null,
                      meta: meta,
                    ),
                  ),
                ],
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
          scale: _scale,
          alignment: mine ? Alignment.bottomRight : Alignment.bottomLeft,
          // The jump marker is a band across the whole row, edge to edge, the
          // way Telegram does it � not a ring around the bubble. A ring is
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
              behavior: HitTestBehavior.translucent,
              // Horizontal only: a vertical drag stays with the list, so the
              // conversation scrolls exactly as before and the gesture arena
              // decides between them on direction rather than on timing.
              // Swiping to reply is off while selecting - the row means one
              // thing at a time.
              // Long-press belongs to the whole message row, not only to the
              // painted bubble — hold anywhere on the line and it answers.
              //
              // What it answers *with* is the spotlight: the room blurs, this
              // message stays lit where it is, and the reactions and actions
              // arrange themselves around it.
              //
              // It used to go straight into selection mode, and that left the
              // menu with no way in at all — reactions, reply, copy, pin,
              // forward, delete were all behind `_showActions`, which was
              // reachable only from the read-by chip: a control that appears on
              // your own messages in a channel and nowhere else. The blurred
              // menu was built and then could not be opened, which is exactly
              // what "I hold it and there is still no blur" was.
              //
              // Selecting has not gone anywhere. It is the first action in the
              // sheet, among the other things you can do to a message rather
              // than in front of all of them. While a selection is already
              // running the hold keeps its old meaning — tick another one —
              // because in that mode the row means one thing.
              onLongPressStart: (details) {
                if (selecting) {
                  ref
                      .read(messageSelectionProvider(widget.chatId).notifier)
                      .toggle(message.id);
                  HapticFeedback.selectionClick();
                  return;
                }
                HapticFeedback.mediumImpact();
                unawaited(_showActions(details.globalPosition));
              },
              onTap: selecting
                  ? () => ref
                      .read(messageSelectionProvider(widget.chatId).notifier)
                      .toggle(message.id)
                  : null,
              // Double-tap belongs to the row for the same reason the hold
              // does. It was wired only to the painted surfaces — the photo,
              // the sticker, the bubble — so on a short message it meant
              // hitting a target a few characters wide, and the empty half of
              // the line beside it did nothing. Anywhere on the line now
              // answers, which is what "не обязательно на смс самой" asked for.
              //
              // Off while selecting: there the row means one thing, and it is
              // the tick.
              onDoubleTap: selecting || !_canReact ? null : _quickReact,
              child: RawGestureDetector(
                // Leftward only, so a drag the other way reaches the page's
                // back gesture instead of being swallowed here. A plain
                // horizontal drag detector accepts at the touch slop whichever
                // way the finger went and then clamps the offset to zero on the
                // right � winning the arena to do nothing, which is why
                // swiping back did not work over the conversation.
                // Registered only when there is a reply to be made.
                //
                // It used to be registered always and refuse inside the
                // handler, which is the worst of both: the recognizer wins the
                // arena, everything else in it loses, and then nothing happens.
                // A bubble that cannot be replied to now lets the drag through
                // to whatever else wanted it instead of eating it.
                gestures: selecting || !_canReply
                    ? const <Type, GestureRecognizerFactory>{}
                    : <Type, GestureRecognizerFactory>{
                        LeftwardDragRecognizer:
                            GestureRecognizerFactoryWithHandlers<
                                LeftwardDragRecognizer>(
                          LeftwardDragRecognizer.new,
                          (r) => r
                            // From the touch, not from where the arena was won:
                            // the slop spent deciding is otherwise thrown away
                            // and the bubble trails the thumb by that much for
                            // the whole gesture.
                            ..dragStartBehavior = DragStartBehavior.down
                            ..onUpdate = _onSwipeUpdate
                            ..onEnd = ((_) => _onSwipeEnd())
                            ..onCancel = _onSwipeEnd,
                        ),
                      },
                child: ValueListenableBuilder<double>(
                  valueListenable: _dragX,
                  // Rebuilt every frame of the gesture: a translate and, past a
                  // pixel of travel, the hint. The bubble itself arrives as
                  // `child` � built once, moved cheaply.
                  builder: (_, dragX, child) => Stack(
                    children: [
                      Transform.translate(
                        offset: Offset(dragX, 0),
                        child: child,
                      ),
                      if (dragX < -1)
                        Positioned.fill(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: _SwipeReplyHint(
                              progress:
                                  (dragX.abs() / _swipeTrigger).clamp(0, 1),
                            ),
                          ),
                        ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment:
                        mine ? MainAxisAlignment.end : MainAxisAlignment.start,
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
                            maxWidth: MediaQuery.sizeOf(context).width * 0.75),
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
                                onDoubleTap: _canReact ? _quickReact : null,
                                child: bubble,
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
/// A shared position: what it is, how precise, and a way out to a real map.
///
/// No tiles. Rendering a map means fetching the square somebody is standing in
/// from a tile server, which tells that server where they are � see
/// [SharedLocation.geoUri]. The phone's own maps app is where the user already
/// decided how they feel about that.
class _SharedLocationBubble extends StatelessWidget {
  const _SharedLocationBubble({required this.location});

  final SharedLocation location;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final expired = location.expired;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 250),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                expired ? Icons.location_off_rounded : Icons.place_rounded,
                size: 20,
                color:
                    expired ? AppColors.textOnGlassDim : AppColors.brandPrimary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t.locationBubbleTitle,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${location.latitude.toStringAsFixed(5)}, '
            '${location.longitude.toStringAsFixed(5)}',
            style:
                AppTypography.mono(size: 11.5, color: AppColors.textOnGlassDim),
          ),
          if (location.accuracyMetres > 0) ...[
            const SizedBox(height: 2),
            Text(
              t.locationAccuracy(location.accuracyMetres),
              style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 11.5),
            ),
          ],
          const SizedBox(height: 8),
          if (expired)
            // The row stays and says so. Hiding it would leave a gap where the
            // sender plainly remembers sending something.
            Text(
              t.locationExpired,
              style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 11.5),
            )
          else
            GestureDetector(
              onTap: () async {
                final uri = location.mapsUri;
                if (!await launchUrl(uri,
                    mode: LaunchMode.externalApplication)) {
                  if (!context.mounted) return;
                  showGlassToast(context, t.locationUnavailable);
                }
              },
              behavior: HitTestBehavior.opaque,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.map_rounded,
                      size: 15, color: AppColors.brandPrimary),
                  const SizedBox(width: 6),
                  Text(
                    t.locationOpenInMaps,
                    style: TextStyle(
                      color: AppColors.brandPrimary,
                      fontSize: 12.5,
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

class _MapFriendLinkBubble extends StatelessWidget {
  const _MapFriendLinkBubble({
    required this.link,
    required this.active,
    required this.mine,
    required this.onTap,
  });

  final MapFriendLink link;
  final bool active;
  final bool mine;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final accepted = active || link.kind == MapFriendLinkKind.accepted;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => unawaited(onTap()),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 210, maxWidth: 250),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    accepted
                        ? Icons.location_on_rounded
                        : Icons.person_add_alt_1_rounded,
                    size: 19,
                    color: AppColors.brandPrimary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      accepted ? t.mapTitle : t.mapInviteTitle,
                      style: TextStyle(
                        color: AppColors.textOnGlass,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                link.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.textOnGlassDim,
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    accepted || mine
                        ? Icons.map_rounded
                        : Icons.check_circle_rounded,
                    size: 15,
                    color: AppColors.brandPrimary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    accepted ? t.mapTitle : t.mapInviteAction(1),
                    style: TextStyle(
                      color: AppColors.brandPrimary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SharedContactBubble extends ConsumerWidget {
  const _SharedContactBubble({
    required this.contact,
    required this.onTap,
  });

  final SharedContact contact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    // Whether the invitation names us, by the sixteen hex characters of our
    // own signing key that a room frame carries.
    final myFingerprint = ref.watch(myChannelFingerprintProvider).value;
    final forMe = contact.invitedMemberId != null &&
        myFingerprint != null &&
        contact.invitedMemberId == myFingerprint;
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
                      // An invitation says so, and says so louder when it is
                      // addressed to the person reading it — in a room where
                      // everybody sees every frame, that is the difference
                      // between "somebody was invited" and "you were".
                      contact.isInvitation
                          ? (forMe
                              ? t.chatContactInvitationForYou
                              : t.chatContactInvitation)
                          : t.profileContactCard,
                      style: TextStyle(
                        color: contact.isInvitation && forMe
                            ? AppColors.brandPrimary
                            : AppColors.textOnGlassDim,
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
            Icons.reply_rounded,
            size: 17,
            color: AppColors.brandPrimary,
          ),
        ),
      ),
    );
  }
}

/// The bottom line of a bubble: what people reacted with, then the clock.
///
/// A [Row] with the reactions flexible and the meta fixed, so a long run of
/// chips wraps inside its own half instead of pushing the time out of the
/// bubble. With nothing to show on the left it collapses to exactly what it
/// used to be — the meta, right-aligned.
class _BubbleFooter extends StatelessWidget {
  const _BubbleFooter({required this.meta, this.reactions});

  final Widget meta;
  final Widget? reactions;

  @override
  Widget build(BuildContext context) {
    if (reactions == null) return meta;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Flexible(child: reactions!),
        const SizedBox(width: 8),
        meta,
      ],
    );
  }
}

/// The dark lozenge the clock sits in when it is drawn over a picture.
///
/// A photo can be any colour under those four characters, including white sky,
/// so the contrast has to be brought along rather than assumed.
class _MetaPill extends StatelessWidget {
  const _MetaPill({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(11),
      ),
      child: child,
    );
  }
}

/// Row of reaction chips shown under a bubble. Each chip is `emoji ?count`
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

/// "Read by N" under one of our own channel messages.
///
/// Deliberately just a count. The names and times are one tap away in the same
/// details popup that already answers "when was this sent / read", because a
/// channel with a dozen members would otherwise put a dozen names under every
/// line � and the count is what anyone glancing at the chat actually wants.
class _ReadByChip extends StatelessWidget {
  const _ReadByChip({required this.label, required this.onTapAt});

  final String label;

  /// Takes the tap's global position, because the details popup opens anchored
  /// to where it was tapped � same as a long-press on the bubble itself.
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
              Icons.done_all_rounded,
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
        // A rounded lozenge rather than a small square badge: it now sits on
        // the bubble's own bottom line beside the clock, and at this size and
        // radius it reads as a chip on the message instead of a second bubble
        // stuck to it.
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: mine
              ? AppColors.brandPrimary.withValues(alpha: 0.26)
              : AppColors.glass(0.14),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: mine
                ? AppColors.brandPrimary.withValues(alpha: 0.65)
                : AppColors.glass(0.18),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              emoji,
              style: const TextStyle(fontSize: 14),
              textScaler: TextScaler.noScaling,
            ),
            if (count > 1) ...[
              const SizedBox(width: 5),
              Text(
                '$count',
                style: TextStyle(
                  color: AppColors.textOnGlass,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
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
/// placeholder block with a spinner � the bubble still occupies space so
/// the list doesn't reflow when the image finally appears.
/// How wide an album is drawn. Wider than a single photo's 220, because a grid
/// of three has to divide it and still show what is in each cell.
const double _kAlbumWidth = 252;

/// A batch of photos as one grid, the way they were sent.
///
/// Deliberately a plain grid rather than Telegram's mosaic, which sizes every
/// cell from its picture's aspect ratio. The mosaic looks better on a set of
/// mixed shapes and is a different feature: it needs each photo's dimensions
/// before the first is decoded, which this app does not record, and would send
/// the layout jumping about as they load. Equal cells need nothing and are
/// stable from the first frame.
///
/// The last row stretches to fill the width instead of leaving a hole where
/// the missing cells would be — five photos read as a row of three and a row of
/// two, not as a row of three and two thirds of a row.
class _AlbumPayload extends StatelessWidget {
  const _AlbumPayload({
    required this.messages,
    required this.chatId,
    this.onDoubleTap,
  });

  final List<Message> messages;
  final String chatId;
  final VoidCallback? onDoubleTap;

  static const _gap = 3.0;

  @override
  Widget build(BuildContext context) {
    final columns = messages.length <= 4 ? 2 : 3;
    final cell = (_kAlbumWidth - _gap * (columns - 1)) / columns;
    final rows = <List<Message>>[];
    for (var i = 0; i < messages.length; i += columns) {
      rows.add(messages.sublist(
        i,
        i + columns > messages.length ? messages.length : i + columns,
      ));
    }

    return SizedBox(
      width: _kAlbumWidth,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var r = 0; r < rows.length; r++) ...[
              if (r > 0) const SizedBox(height: _gap),
              SizedBox(
                height: cell,
                child: Row(
                  children: [
                    for (var c = 0; c < rows[r].length; c++) ...[
                      if (c > 0) const SizedBox(width: _gap),
                      Expanded(
                        child: _AlbumCell(
                          message: rows[r][c],
                          chatId: chatId,
                          width: cell,
                          onDoubleTap: onDoubleTap,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AlbumCell extends StatelessWidget {
  const _AlbumCell({
    required this.message,
    required this.chatId,
    required this.width,
    this.onDoubleTap,
  });

  final Message message;
  final String chatId;

  /// The drawn width, which is also the decode width — a grid of nine photos
  /// decoded at the size they were sent is the single most expensive thing a
  /// conversation can ask of this phone.
  final double width;
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final path = message.imagePath;
    if (path == null || !MediaPaths.exists(path)) {
      return _ImagePlaceholder(
        icon: message.status == MessageStatus.failed
            ? Icons.broken_image_rounded
            : Icons.image_rounded,
        label: '',
        spinning: message.status == MessageStatus.sending,
      );
    }
    return GestureDetector(
      onDoubleTap: onDoubleTap,
      // Straight to this photo, not to the album's first — tapping the fourth
      // picture and being shown the first is the sort of thing that makes a
      // grid feel like a picture of a grid.
      onTap: () => Navigator.of(context).push(
        mediaRoute<void>(
          (_) => ChatMediaGalleryScreen(
            chatId: chatId,
            initialMessageId: message.id,
          ),
        ),
      ),
      child: Hero(
        tag: 'image-${message.id}',
        child: Image.file(
          File(path),
          fit: BoxFit.cover,
          cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
          errorBuilder: (_, __, ___) => _ImagePlaceholder(
            icon: Icons.broken_image_rounded,
            label: '',
          ),
        ),
      ),
    );
  }
}

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
  /// arena outright � so without this the second tap of a double-tap would just
  /// open the gallery and the reaction would never fire. Registering both on the
  /// same detector lets Flutter hold the single tap until the double-tap window
  /// closes, which costs the viewer a barely perceptible delay and is what makes
  /// the gesture work on media at all.
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final path = message.imagePath;
    final fileExists = path != null && MediaPaths.exists(path);

    // A view-once photo never renders as a thumbnail. The whole point is that
    // it is looked at deliberately, once � a picture you can scroll past twice
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
              // No rounding of its own any more: the bubble clips to its own
              // corners now that the photo reaches them, and a second, tighter
              // radius inside that one drew a visible sliver of bubble in each
              // corner — the frame this change exists to remove, only thinner.
              child: ClipRRect(
                borderRadius: BorderRadius.zero,
                child: Image.file(
                  File(path),
                  // A sticker is drawn whole, not cropped to a square: it has a
                  // shape, usually with transparency around it, and cover would
                  // trim exactly the part that gives it one.
                  fit: message.isSticker ? BoxFit.contain : BoxFit.cover,
                  // Decoded at the size it is drawn, not the size it was sent.
                  //
                  // Without this the bubble decodes the whole photo � the mesh
                  // encoder tops out around 1600 px, so that is a 1600?1600
                  // bitmap, ten megabytes of it, to fill a box 220 points
                  // wide. Every photo in the conversation, held in the image
                  // cache. Scrolling a chat with pictures in it then costs a
                  // full-resolution decode per photo and a texture upload to
                  // match, which is most of why such a chat warms the phone.
                  // At the drawn size it is a twenty-fifth of the pixels.
                  cacheWidth: ((message.isSticker
                              ? kStickerWidth
                              : photoBubbleWidth(context)) *
                          MediaQuery.devicePixelRatioOf(context))
                      .round(),
                  errorBuilder: (_, __, ___) => _ImagePlaceholder(
                    icon: Icons.broken_image_rounded,
                    label: message.imageMime ?? 'image',
                  ),
                ),
              ),
            ),
          )
        : _ImagePlaceholder(
            icon: message.status == MessageStatus.failed
                ? Icons.broken_image_rounded
                : Icons.image_rounded,
            label: message.imageMime ?? message.text,
            spinning: message.status == MessageStatus.sending,
          );

    final width = message.isSticker ? kStickerWidth : photoBubbleWidth(context);
    return ConstrainedBox(
      // Stickers keep a size of their own — see [kStickerWidth]. A photo takes
      // the width it is given and as much height as its own shape asks for,
      // capped so a panorama shot in portrait cannot become a bubble you have
      // to scroll past.
      constraints: BoxConstraints(
        maxWidth: width,
        maxHeight: message.isSticker ? kStickerWidth : width * 1.25,
      ),
      child: body,
    );
  }
}

/// Whether tapping a view-once bubble may open the photo.
///
/// Never for our own: a photo you sent is gone from here the moment it leaves,
/// the way Telegram treats one. It used to stay openable until the recipient's
/// ack came back, which read as "still mine for now" and was worse than it
/// sounds � the viewer fired the same "I have seen it" notice for it, so
/// glancing at what you sent destroyed the copy the other person had not
/// opened. There is nothing to look at anyway now: an outgoing view-once photo
/// is never written to this phone's disk.
///
/// [fileExists] is the received half � the bytes may still be arriving, or have
/// already been burned.
bool viewOnceCanBeOpened(Message message, {required bool fileExists}) =>
    !message.isMine && !message.viewOnceConsumed && fileExists;

/// The states a view-once photo can be in: waiting to be opened, spent, still
/// arriving, or one of ours that was sent.
///
/// Deliberately never the picture itself. Tapping opens
/// [ViewOnceMediaScreen] � not the swipeable gallery, which has Share and
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
                  ? Icons.visibility_off_rounded
                  : mine
                      ? Icons.done_rounded
                      : Icons.local_fire_department_rounded,
              size: 20,
              color:
                  spent ? AppColors.textOnGlassFaint : AppColors.brandPrimary,
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
                  color: spent
                      ? AppColors.textOnGlassFaint
                      : AppColors.textOnGlass,
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

/// The filling circle over a picture that is still on its way out.
///
/// Reads [mediaSendProgressProvider], which the send loop reports chunks to. A
/// transfer that has not reported yet — the manifest is still going, or this is
/// a build that predates the reporting — shows an indeterminate spinner rather
/// than an empty ring sitting at zero, because those two look identical and
/// mean opposite things.
class _SendProgressRing extends ConsumerWidget {
  const _SendProgressRing({required this.messageId});

  final String messageId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(mediaSendProgressProvider)[messageId];
    return Center(
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.42),
          shape: BoxShape.circle,
        ),
        padding: const EdgeInsets.all(9),
        child: TweenAnimationBuilder<double>(
          // Chunk reports arrive in visible steps; the ring should sweep
          // between them rather than tick.
          tween: Tween<double>(begin: 0, end: value ?? 0),
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
          builder: (context, animated, _) => CircularProgressIndicator(
            value: value == null ? null : animated,
            strokeWidth: 2.4,
            backgroundColor: Colors.white.withValues(alpha: 0.28),
            color: AppColors.brandPrimary,
          ),
        ),
      ),
    );
  }
}

class _BubbleMeta extends StatelessWidget {
  const _BubbleMeta({
    required this.message,
    this.pinned = false,
    this.onMedia = false,
    this.tag,
  });

  final Message message;

  /// The saved-note tag on this message, or null. Shown at the head of the
  /// meta line so a tagged note reads as tagged without opening it — the same
  /// place a pin or a shield sits, for the same reason.
  final String? tag;

  /// True when this is the chat's pinned message.
  final bool pinned;

  /// True when this row is drawn over the picture rather than under it, on the
  /// dark pill — where the sender's own tint is the wrong contrast to reach
  /// for, because what is behind it is a photograph and not a bubble.
  final bool onMedia;

  /// Distinct tint for a "read" tick so it reads apart from plain delivery.
  static const _readColor = Color(0xFF66D9FF);

  /// The ink for everything in this row, given what it is drawn on.
  Color _ink(double onBubble) =>
      onMedia ? Colors.white.withValues(alpha: 0.95) : AppColors.ink(onBubble);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final time = formatBubbleTime(context, message.sentAt);

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (tag != null) ...[
          Text(tag!, style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 4),
        ],
        if (pinned) ...[
          Icon(
            Icons.push_pin_rounded,
            size: 11,
            color: _ink(message.isMine ? 0.8 : 0.55),
            semanticLabel: t.chatPinnedTitle,
          ),
          const SizedBox(width: 4),
        ],
        if (message.forwardSecret) ...[
          Icon(
            Icons.lock_clock_rounded,
            size: 11,
            color: _ink(message.isMine ? 0.8 : 0.55),
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
              color: _ink(message.isMine ? 0.7 : 0.45),
            ),
          ),
          const SizedBox(width: 4),
        ],
        Text(
          time,
          style: TextStyle(
            fontSize: 10.5,
            color: _ink(message.isMine ? 0.8 : 0.5),
          ),
        ),
        if (message.isMine) ...[
          const SizedBox(width: 4),
          Icon(
            switch (message.status) {
              MessageStatus.sending => Icons.schedule_rounded,
              MessageStatus.delivered => Icons.done_rounded,
              MessageStatus.read => Icons.done_all_rounded,
              MessageStatus.failed => Icons.error_outline_rounded,
            },
            size: 12,
            color: switch (message.status) {
              MessageStatus.failed => AppColors.danger,
              MessageStatus.read => _readColor,
              _ => _ink(0.85),
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
