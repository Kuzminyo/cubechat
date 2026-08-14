import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/identity/anon_name.dart';
import '../../../core/identity/nickname_controller.dart';
import '../../../core/theme/colors.dart';
import '../../../core/util/share_anchor.dart';
import '../../../core/utils/time_format.dart';
import '../../../l10n/app_localizations.dart';
import '../../peers/data/contact_aliases_controller.dart';
import '../../peers/data/known_peers_controller.dart';
import '../data/chat_navigation.dart';
import '../../../core/util/media_storage.dart';
import '../data/conversation_settings_controller.dart';
import '../data/messages_controller.dart';
import '../models/message.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../stickers/data/sticker_library.dart';

/// Telegram-style media browser: every image in a conversation, full-screen and
/// swipeable, with pinch-zoom, save-to-gallery and share. Opened from an image
/// bubble at that image's position; swiping pages through the rest.
class ChatMediaGalleryScreen extends ConsumerStatefulWidget {
  const ChatMediaGalleryScreen({
    super.key,
    required this.chatId,
    required this.initialMessageId,
  });

  final String chatId;
  final String initialMessageId;

  @override
  ConsumerState<ChatMediaGalleryScreen> createState() =>
      _ChatMediaGalleryScreenState();
}

class _ChatMediaGalleryScreenState
    extends ConsumerState<ChatMediaGalleryScreen> {
  late final PageController _controller;
  int _index = 0;
  bool _saving = false;

  /// Header on or off. Starts on so the actions are discoverable, and a tap
  /// on the photo takes it away.
  bool _chromeVisible = true;

  /// How far a downward drag has carried the picture, in pixels.
  ///
  /// Swipe-down-to-close is how every photo viewer on a phone is dismissed, and
  /// this one only had a back button in a corner that the chrome tap could hide.
  double _dragY = 0;

  /// Past this the picture goes rather than springs back — or any downward
  /// flick, however short, because a flick has already said what it means.
  static const double _dismissAfter = 120;
  static const double _dismissVelocity = 700;

  /// The photo shrinks and the black recedes as it is pulled, so the
  /// conversation showing through says where it is going.
  double get _dragProgress => (_dragY.abs() / 400).clamp(0.0, 1.0);

  void _onDragUpdate(DragUpdateDetails d) =>
      setState(() => _dragY = (_dragY + d.delta.dy).clamp(0.0, 1000.0));

  void _onDragEnd(DragEndDetails d) {
    final velocity = d.velocity.pixelsPerSecond.dy;
    if (_dragY > _dismissAfter || velocity > _dismissVelocity) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() => _dragY = 0);
  }

  /// Snapshot the image list once so paging isn't disturbed if a new message
  /// arrives mid-view; still enough for the common "look through photos" flow.
  late final List<Message> _images = _collectImages();

  List<Message> _collectImages() {
    final msgs = ref.read(messagesControllerProvider)[widget.chatId] ??
        const <Message>[];
    return msgs
        .where(
          (m) =>
              m.kind == MessageKind.image &&
              // Never reachable from the browser, even indirectly by paging
              // into it from a neighbouring photo. This screen can share and
              // save what it shows.
              !m.viewOnce &&
              MediaPaths.existsOrNull(m.imagePath),
        )
        .toList();
  }

  @override
  void initState() {
    super.initState();
    final start = _images.indexWhere((m) => m.id == widget.initialMessageId);
    _index = start < 0 ? 0 : start;
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Message? get _current =>
      (_index >= 0 && _index < _images.length) ? _images[_index] : null;

  /// The share control lives in the AppBar, so the handler has no context of
  /// its own to measure — hence the key.
  final _shareButtonKey = GlobalKey();

  Future<void> _share() async {
    final path = _current?.imagePath;
    if (path == null) return;
    try {
      await Share.shareXFiles(
        [XFile(path)],
        // Required, not optional: iOS raises without a non-empty anchor, on
        // iPhone as well as iPad. See [shareAnchorFor].
        sharePositionOrigin: shareAnchorFor(context, key: _shareButtonKey),
      );
    } catch (e) {
      _toast('Could not share: $e', ok: false);
    }
  }

  /// Keep this picture as a sticker.
  ///
  /// A copy, not a reference: the message it came from can be deleted, its
  /// history cleared, or the whole chat auto-expired, and a sticker that
  /// vanished with it would be a strange thing to have kept.
  Future<void> _keepAsSticker() async {
    final path = _current?.imagePath;
    if (path == null) return;
    await ref.read(stickerLibraryProvider.notifier).keep(path);
    if (!mounted) return;
    showGlassToast(context, AppLocalizations.of(context).stickerKept);
  }

  Future<void> _save() async {
    final msg = _current;
    final path = msg?.imagePath;
    if (path == null || _saving) return;
    setState(() => _saving = true);
    try {
      final bytes = await File(path).readAsBytes();
      final ext = _extFor(msg!.imageMime, path);
      final result = await SaverGallery.saveImage(
        bytes,
        fileName: 'cubechat_${msg.id}$ext',
        skipIfExists: false,
      );
      _toast(result.isSuccess ? 'Saved to gallery' : 'Save failed',
          ok: result.isSuccess);
    } catch (e) {
      _toast('Save failed: $e', ok: false);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String message, {bool ok = true}) {
    if (!mounted) return;
    showGlassToast(
      context,
      message,
      icon: ok ? Icons.download_done_rounded : null,
      tone: ok ? ToastTone.success : ToastTone.danger,
    );
  }

  @override
  Widget build(BuildContext context) {
    final sharingRestricted = ref
            .watch(conversationSettingsControllerProvider)[widget.chatId]
            ?.copyingRestricted ??
        false;
    final t = AppLocalizations.of(context);
    final count = _images.length;
    final current = _current;
    return Scaffold(
      // The black lets go as the picture is pulled, so the conversation shows
      // through and the gesture reads as "back to the chat" rather than "some
      // photo is moving".
      backgroundColor: Colors.black.withValues(alpha: 1 - _dragProgress),
      extendBodyBehindAppBar: true,
      // Hidden while the photo is being looked at rather than operated on. The
      // chrome is worth a tap to bring back and worth nothing while it sits on
      // top of the picture.
      appBar: !_chromeVisible
          ? null
          : AppBar(
              backgroundColor: Colors.black.withValues(alpha: 0.45),
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              titleSpacing: 0,
              // Who sent it and when, which is what you actually want to know
              // looking at a photo three hundred messages back — the old header
              // said "4 / 17", a number that answers a question nobody asks.
              title: current == null
                  ? null
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _senderName(current),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          count > 1
                              ? '${formatMessageDetailsTime(context, current.sentAt)}'
                                  '  ·  ${_index + 1}/$count'
                              : formatMessageDetailsTime(context, current.sentAt),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.65),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
              actions: [
                if (!sharingRestricted)
                  IconButton(
                    key: _shareButtonKey,
                    icon: const Icon(Icons.ios_share, color: Colors.white),
                    tooltip: t.chatMediaShare,
                    onPressed: current == null ? null : _share,
                  ),
                PopupMenuButton<String>(
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.more_vert, color: Colors.white),
                  color: AppColors.bgTop,
                  onSelected: (value) {
                    if (value == 'save') {
                      unawaited(_save());
                    } else if (value == 'chat') {
                      _showInChat();
                    } else if (value == 'sticker') {
                      unawaited(_keepAsSticker());
                    }
                  },
                  itemBuilder: (_) => [
                    // Saving to the camera roll leaves the conversation as
                    // surely as the share sheet does — more so, since what it
                    // leaves behind is a copy in an album that syncs. Hiding
                    // one and offering the other would have made the setting
                    // decorative.
                    if (!sharingRestricted)
                      PopupMenuItem(
                        value: 'save',
                        child: _menuRow(
                            Icons.download_rounded, t.chatMediaSaveToGallery),
                      ),
                    PopupMenuItem(
                      value: 'chat',
                      child: _menuRow(
                          Icons.chat_bubble_outline_rounded, t.chatMediaShowInChat),
                    ),
                    // Kept inside the app rather than exported, so this one
                    // stays offered even when sharing is restricted: the
                    // picture does not leave the conversation, it stays in it
                    // and becomes reusable.
                    PopupMenuItem(
                      value: 'sticker',
                      child: _menuRow(
                          Icons.emoji_emotions_outlined, t.stickerKeep),
                    ),
                  ],
                ),
              ],
            ),
      body: count == 0
          ? _missing()
          : GestureDetector(
              // Tap anywhere to get the chrome out of the way, the way every
              // photo viewer works.
              onTap: () => setState(() => _chromeVisible = !_chromeVisible),
              // Vertical only: the horizontal axis belongs to the PageView, and
              // pinch-zoom belongs to the InteractiveViewer inside it. A drag
              // that starts as a scale gesture never reaches here, so a
              // two-finger zoom cannot close the picture by accident.
              onVerticalDragUpdate: _onDragUpdate,
              onVerticalDragEnd: _onDragEnd,
              onVerticalDragCancel: () => setState(() => _dragY = 0),
              child: Transform.translate(
                offset: Offset(0, _dragY),
                child: Transform.scale(
                  scale: 1 - 0.15 * _dragProgress,
                  child: PageView.builder(
                controller: _controller,
                itemCount: count,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (_, i) {
                  final m = _images[i];
                  return InteractiveViewer(
                    minScale: 0.8,
                    maxScale: 8,
                    child: Center(
                      child: Hero(
                        tag: 'image-${m.id}',
                        child: Image.file(
                          File(m.imagePath!),
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => _missing(),
                        ),
                      ),
                    ),
                  );
                },
                  ),
                ),
              ),
            ),
    );
  }

  Widget _menuRow(IconData icon, String label) => Row(
        children: [
          Icon(icon, size: 19, color: AppColors.textOnGlass),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: AppColors.textOnGlass)),
        ],
      );

  /// Whoever sent this photo, resolved the way the rest of the app resolves a
  /// name: your alias for them first, then what they broadcast.
  String _senderName(Message message) {
    if (message.isMine) {
      final mine = ref.read(nicknameControllerProvider).trim();
      return mine.isEmpty ? AppLocalizations.of(context).chatReplyYou : mine;
    }
    final author = message.authorName?.trim();
    if (author != null && author.isNotEmpty) return author;
    final peer = ref.read(knownPeersControllerProvider)[widget.chatId];
    if (peer == null) return AppLocalizations.of(context).bleUnknownPeer;
    return contactDisplayName(
      alias: ref.read(contactAliasesControllerProvider)[peer.pubkeyHex],
      rawBroadcastName: peer.displayName,
      pubkeyHex: peer.pubkeyHex,
    );
  }

  /// Close the viewer and land on this photo's bubble in the conversation.
  void _showInChat() {
    final wireId = _current?.wireId;
    Navigator.of(context).maybePop();
    if (wireId == null) return;
    ref.read(chatJumpRequestProvider(widget.chatId).notifier).state = wireId;
  }

  Widget _missing() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.broken_image_outlined,
              color: AppColors.textOnGlassDim,
              size: 56,
            ),
            const SizedBox(height: 12),
            Text(
              'image not available',
              style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
            ),
          ],
        ),
      );
}

String _extFor(String? mime, String path) {
  switch ((mime ?? '').toLowerCase()) {
    case 'image/png':
      return '.png';
    case 'image/webp':
      return '.webp';
    case 'image/gif':
      return '.gif';
    case 'image/jpeg':
    case 'image/jpg':
      return '.jpg';
  }
  final lower = path.toLowerCase();
  for (final e in ['.png', '.webp', '.gif', '.jpg', '.jpeg']) {
    if (lower.endsWith(e)) return e;
  }
  return '.jpg';
}
