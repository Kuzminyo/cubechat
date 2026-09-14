import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../../core/identity/anon_name.dart';
import '../../../core/identity/nickname_controller.dart';
import '../../../core/theme/colors.dart';
import '../../../core/util/open_in.dart';
import '../../../core/util/share_anchor.dart';
import '../../../core/utils/time_format.dart';
import '../../../l10n/app_localizations.dart';
import '../../peers/data/contact_aliases_controller.dart';
import '../../peers/data/known_peers_controller.dart';
import '../data/chat_navigation.dart';
import '../../../core/util/media_storage.dart';
import '../data/conversation_settings_controller.dart';
import '../data/messages_controller.dart';
import '../data/video_frames.dart';
import '../models/message.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../stickers/data/sticker_library.dart';
import 'widgets/emoji_picker_sheet.dart';
import 'widgets/photo_flight.dart';
import 'widgets/media_photo_surface.dart';
import '../../../core/util/motion.dart';

/// Telegram-style media browser: every photo and clip in a conversation,
/// full-screen and swipeable, with pinch-zoom, save-to-gallery and share.
/// Opened from a photo or a clip at its own position; swiping pages through
/// the rest, and a tap on a clip plays or pauses it.
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

  void _onDragUpdate(double dy) =>
      setState(() => _dragY = (_dragY + dy).clamp(0.0, 1000.0));

  void _onDragEnd(double velocity) {
    if (_dragY > _dismissAfter || velocity > _dismissVelocity) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() => _dragY = 0);
  }

  double? _pageDragOrigin;

  void _onPageDrag(double dx) {
    _pageDragOrigin ??= _controller.page ?? _index.toDouble();
    final position = _controller.position;
    _controller.jumpTo(
      (position.pixels - dx).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  void _onPageEnd(double velocity) {
    final origin = _pageDragOrigin;
    _pageDragOrigin = null;
    if (origin == null || !_controller.hasClients) return;
    final target = velocity.abs() > 500
        ? origin.round() + (velocity < 0 ? 1 : -1)
        : (_controller.page ?? origin).round();
    unawaited(
      _controller.animateToPage(
        target.clamp(0, _images.length - 1),
        duration: AppMotion.duration(context, AppMotion.control),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  /// Snapshot the image list once so paging isn't disturbed if a new message
  /// arrives mid-view; still enough for the common "look through photos" flow.
  late final List<Message> _images = _collectImages();

  /// A clip out of the gallery, not a circle: circles have their own player
  /// and their own island.
  static bool _isClip(Message m) =>
      m.kind == MessageKind.file &&
      !m.isCircle &&
      !m.viewOnce &&
      m.text.toLowerCase().startsWith('video/') &&
      MediaPaths.existsOrNull(m.filePath);

  /// Decided once with the list: [_isClip] asks the disk.
  late final Set<String> _clipIds = {
    for (final m in _images)
      if (m.kind == MessageKind.file) m.id,
  };

  bool _clip(Message m) => _clipIds.contains(m.id);

  String? _pathOf(Message m) => _clip(m) ? m.filePath : m.imagePath;

  List<Message> _collectImages() {
    final msgs = ref.read(messagesControllerProvider)[widget.chatId] ??
        const <Message>[];
    return msgs
        .where(
          (m) =>
              _isClip(m) ||
              m.kind == MessageKind.image &&
              // Never reachable from the browser, even indirectly by paging
              // into it from a neighbouring photo. This screen can share and
              // save what it shows.
              !m.viewOnce &&
              // Nor a sticker. It carries an image, but it is a gesture rather
              // than a picture — it no longer opens when tapped, and paging
              // into one from the photo beside it would put it back where it
              // was taken out of.
              !m.isSticker &&
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
    final current = _current;
    final path = current == null ? null : _pathOf(current);
    if (path == null) return;
    final anchor = shareAnchorFor(context, key: _shareButtonKey);
    // "Send it to Telegram" means Telegram opens, and on iOS the share sheet
    // does not do that: it runs the chosen app's *share extension*, a window
    // belonging to that app drawn over this one, so the phone never leaves
    // cubechat. The hand-off does leave — it copies the file across and
    // launches the app — and the file bubble has used it for exactly this
    // reason since it was written; a photo went out through the sheet only
    // because nobody had wired it up here.
    if (OpenIn.isSupported) {
      if (await OpenIn.handOff(path, anchor: anchor)) return;
      if (!mounted) return;
    }
    try {
      await Share.shareXFiles(
        [XFile(path)],
        // Required, not optional: iOS raises without a non-empty anchor, on
        // iPhone as well as iPad. See [shareAnchorFor].
        sharePositionOrigin: anchor,
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
    final t = AppLocalizations.of(context);
    final emoji = await showEmojiPicker(context, title: t.stickerEmojiTitle);
    if (!mounted) return;
    final kept = await ref
        .read(stickerLibraryProvider.notifier)
        .keep(path, emoji: emoji);
    if (!mounted) return;
    showGlassToast(
      context,
      kept ? t.stickerKept : t.stickerFailed,
      icon: kept ? Icons.auto_awesome_rounded : null,
      tone: kept ? ToastTone.success : ToastTone.danger,
    );
  }

  Future<void> _save() async {
    final msg = _current;
    final path = msg == null ? null : _pathOf(msg);
    if (path == null || _saving) return;
    setState(() => _saving = true);
    try {
      if (_clip(msg!)) {
        final dot = path.lastIndexOf('.');
        final result = await SaverGallery.saveFile(
          filePath: path,
          fileName:
              'cubechat_${msg.id}${dot < 0 ? '.mp4' : path.substring(dot)}',
          skipIfExists: false,
        );
        _toast(
          result.isSuccess ? 'Saved to gallery' : 'Save failed',
          ok: result.isSuccess,
        );
        return;
      }
      final bytes = await File(path).readAsBytes();
      final ext = _extFor(msg.imageMime, path);
      final result = await SaverGallery.saveImage(
        bytes,
        fileName: 'cubechat_${msg.id}$ext',
        skipIfExists: false,
      );
      _toast(
        result.isSuccess ? 'Saved to gallery' : 'Save failed',
        ok: result.isSuccess,
      );
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
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
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
                              : formatMessageDetailsTime(
                                  context,
                                  current.sentAt,
                                ),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.65),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
              actions: [
                // Saving is its own button rather than the third line of an
                // overflow menu. Keeping a picture is the commonest thing
                // anybody does in a full-screen viewer, and behind two taps
                // and a menu nobody found it — the request that produced this
                // was "let me save photos to the gallery", of a build that
                // already could.
                IconButton(
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          Icons.download_rounded,
                          // Dimmed, not gone: the other side asked that this
                          // conversation not be copied out of, and a control
                          // that vanishes reads as a broken app rather than as
                          // an answer.
                          color: Colors.white
                              .withValues(alpha: sharingRestricted ? 0.3 : 1),
                        ),
                  tooltip: t.chatMediaSaveToGallery,
                  onPressed: current == null || sharingRestricted || _saving
                      ? null
                      : () => unawaited(_save()),
                ),
                if (!sharingRestricted)
                  IconButton(
                    key: _shareButtonKey,
                    icon: const Icon(Icons.share_rounded, color: Colors.white),
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
                      : const Icon(
                          Icons.more_vert_rounded,
                          color: Colors.white,
                        ),
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
                          Icons.download_rounded,
                          t.chatMediaSaveToGallery,
                        ),
                      ),
                    PopupMenuItem(
                      value: 'chat',
                      child: _menuRow(
                        Icons.chat_bubble_outline_rounded,
                        t.chatMediaShowInChat,
                      ),
                    ),
                    // Kept inside the app rather than exported, so this one
                    // stays offered even when sharing is restricted: the
                    // picture does not leave the conversation, it stays in it
                    // and becomes reusable.
                    if (current == null || !_clip(current))
                      PopupMenuItem(
                        value: 'sticker',
                        child: _menuRow(
                          Icons.emoji_emotions_rounded,
                          t.stickerKeep,
                        ),
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
              // The photo owns scale/pan and routes a one-finger gesture to
              // close or page. Competing parent drag recognizers lost touches.
              child: Transform.translate(
                offset: Offset(0, _dragY),
                child: Transform.scale(
                  scale: 1 - 0.15 * _dragProgress,
                  child: PageView.builder(
                    controller: _controller,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: count,
                    onPageChanged: (i) => setState(() => _index = i),
                    itemBuilder: (_, i) {
                      final m = _images[i];
                      if (_clip(m)) {
                        return MediaPhotoSurface(
                          key: ValueKey(m.id),
                          onDismissUpdate: _onDragUpdate,
                          onDismissEnd: _onDragEnd,
                          onDismissCancel: () => setState(() => _dragY = 0),
                          onPageUpdate: _onPageDrag,
                          onPageEnd: _onPageEnd,
                          child: _ClipPage(
                            path: m.filePath!,
                            active: i == _index,
                          ),
                        );
                      }
                      return MediaPhotoSurface(
                        key: ValueKey(m.id),
                        onDismissUpdate: _onDragUpdate,
                        onDismissEnd: _onDragEnd,
                        onDismissCancel: () => setState(() => _dragY = 0),
                        onPageUpdate: _onPageDrag,
                        onPageEnd: _onPageEnd,
                        child: Center(
                          child: Hero(
                            tag: 'image-${m.id}',
                            // The destination's builder is the one Flutter
                            // asks for on a push, so the crossing has to be
                            // named here as well as on the bubble.
                            flightShuttleBuilder:
                                photoFlightShuttle(m.imagePath!),
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
              Icons.broken_image_rounded,
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

/// One clip, full screen: its first frame at once, then the clip itself,
/// playing from the moment its page is the one on screen. A tap plays or
/// pauses it; paging away pauses it and hands the decoder back.
class _ClipPage extends StatefulWidget {
  const _ClipPage({required this.path, required this.active});

  final String path;
  final bool active;

  @override
  State<_ClipPage> createState() => _ClipPageState();
}

class _ClipPageState extends State<_ClipPage> {
  VideoPlayerController? _player;
  bool _failed = false;

  /// Stopped by a tap rather than by the clip reaching its end.
  bool _pausedByTap = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) unawaited(_open());
  }

  @override
  void didUpdateWidget(_ClipPage old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      _pausedByTap = false;
      final player = _player;
      if (player == null) {
        unawaited(_open());
      } else {
        unawaited(player.play());
      }
    } else if (!widget.active && old.active) {
      unawaited(_player?.pause());
    }
  }

  Future<void> _open() async {
    if (_player != null || _failed) return;
    final player = VideoPlayerController.file(File(widget.path));
    try {
      await player.initialize();
      if (!mounted) {
        await player.dispose();
        return;
      }
      player.addListener(_onTick);
      setState(() => _player = player);
      if (widget.active && !_pausedByTap) await player.play();
    } catch (_) {
      await player.dispose();
      if (mounted) setState(() => _failed = true);
    }
  }

  bool _wasPlaying = false;

  /// Only what the controls show: whether it plays, and where it is to the
  /// quarter second. The texture repaints itself; rebuilding this page at the
  /// player's own rate for a progress bar is the cost it does not need.
  void _onTick() {
    final value = _player?.value;
    if (value == null || !mounted) return;
    final quarter = value.position.inMilliseconds ~/ 250;
    if (value.isPlaying != _wasPlaying || quarter != _lastQuarter) {
      _wasPlaying = value.isPlaying;
      _lastQuarter = quarter;
      setState(() {});
    }
  }

  int _lastQuarter = -1;

  Future<void> _toggle() async {
    final player = _player;
    if (player == null) {
      _pausedByTap = false;
      await _open();
      return;
    }
    if (player.value.isPlaying) {
      _pausedByTap = true;
      await player.pause();
    } else {
      _pausedByTap = false;
      if (player.value.position >= player.value.duration) {
        await player.seekTo(Duration.zero);
      }
      await player.play();
    }
  }

  @override
  void dispose() {
    _player?.removeListener(_onTick);
    unawaited(_player?.dispose());
    super.dispose();
  }

  static String _clock(Duration d) {
    final s = d.inSeconds.clamp(0, 359999);
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final ready = player != null && player.value.isInitialized;
    final poster = VideoFrames.peek(widget.path);
    final playing = ready && player.value.isPlaying;
    final position = ready ? player.value.position : Duration.zero;
    final total = ready ? player.value.duration : (poster?.length ?? Duration.zero);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(_toggle()),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: ready
                ? AspectRatio(
                    aspectRatio: player.value.aspectRatio,
                    child: VideoPlayer(player),
                  )
                : poster?.frame != null
                    ? Image.file(File(poster!.frame!), fit: BoxFit.contain)
                    : const SizedBox.shrink(),
          ),
          if (!playing)
            Center(
              child: _failed
                  ? Icon(
                      Icons.broken_image_rounded,
                      color: AppColors.textOnGlassDim,
                      size: 56,
                    )
                  : Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        size: 44,
                        color: Colors.white,
                      ),
                    ),
            ),
          if (ready)
            Positioned(
              left: 16,
              right: 16,
              bottom: MediaQuery.paddingOf(context).bottom + 20,
              child: Row(
                children: [
                  Text(
                    _clock(position),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: total.inMilliseconds == 0
                            ? 0
                            : (position.inMilliseconds / total.inMilliseconds)
                                .clamp(0.0, 1.0),
                        minHeight: 3,
                        backgroundColor: Colors.white24,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _clock(total),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontFeatures: [FontFeature.tabularFigures()],
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
