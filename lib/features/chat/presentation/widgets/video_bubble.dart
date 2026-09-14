import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/util/transition_probe.dart';
import '../../../../core/routing/page_transitions.dart';
import '../../data/video_frames.dart';
import '../../models/message.dart';
import '../../data/voice_playback_controller.dart';
import '../chat_media_gallery_screen.dart';
import 'message_bubble.dart' show photoBubbleWidth;
import 'playback_author.dart';

/// A clip opens full screen, the way a photo does; circles share the
/// voice-note player and island. Neither holds a video decoder while it is
/// only being scrolled past: both draw their first frame, see [VideoFrames].
class VideoBubble extends ConsumerStatefulWidget {
  const VideoBubble({
    super.key,
    required this.message,
    this.onLongPress,
    this.chatId,
  });

  final Message message;
  final String? chatId;
  final VoidCallback? onLongPress;

  /// The width a clip is drawn at.
  ///
  /// The comment here used to say "matching the photo bubble beside it" and the
  /// number did not: a photo is `photoBubbleWidth`, 68% of the screen clamped
  /// to 220–300, so on any phone wider than 324 points the clip was the
  /// narrower of the two and a conversation with both in it had two column
  /// widths. 220 was only ever the *floor* of that range.
  ///
  /// Kept as a fallback for a caller with no context to measure from; the
  /// bubble itself now asks [photoBubbleWidth] the same question the photo
  /// does, so the two cannot drift apart again.
  static const double width = 220;

  /// The name a circle is sent under.
  ///
  /// A circle travels as an ordinary video file — same transport, same media
  /// relay lane — and is told apart from a clip out of the gallery by this
  /// reserved name. A media kind of its own would read better on the wire and
  /// receive worse: an older build throws on an unknown kind and drops the
  /// transfer, so the circle would never arrive there at all, where a reserved
  /// name lands as a video it can play. Same reasoning as the `cubechat:*:v1:`
  /// markers that ride inside ordinary text.
  static const String circleFileName = Message.circleFileName;

  /// Drawn round and square rather than as a rectangle in a card.
  static bool isCircle(Message message) => message.isCircle;

  /// Resting, and tapped.
  ///
  /// At rest a circle is one of many things in a scrolling column. Tapped, it
  /// becomes the thing on screen: most of the width, the way Telegram draws a
  /// round message that is playing, and asked for by name. The one that is
  /// speaking should be the one your eye lands on.
  static const double circleIdle = 200;

  /// The width of the screen less the row's margins on both sides and a little
  /// room beside the disc, capped so a tablet does not get a dinner plate.
  static double circleExpanded(double screenWidth) =>
      (screenWidth - 52).clamp(circleIdle, 340.0);

  /// How tall a clip is drawn, given the width a photo would take and the
  /// shape the camera recorded.
  ///
  /// The width was shared with the photo bubble already; the height was not,
  /// and only a clip out of a phone camera showed it. A 9:16 portrait at the
  /// 300-point ceiling came out 533 points tall — a bubble that fills a screen
  /// on its own and has to be scrolled past. A photo has been capped at 1.25x
  /// its width since the panorama report and is cropped rather than
  /// letterboxed when it hits the cap; this is the same rule, and `BoxFit.cover`
  /// in the bubble does the same cropping.
  ///
  /// The floor is the ceiling's mirror: a cinema-wide clip is still something
  /// to look at, and below about half the width it is a strip.
  static double rectangleHeight(double width, double aspect) =>
      (width / (aspect <= 0 ? 16 / 9 : aspect))
          .clamp(width * 0.5, width * 1.25);

  /// True when this message is a video we can actually play: a file, with a
  /// video mime, whose bytes are on this phone.
  static bool handles(Message message) {
    if (message.kind != MessageKind.file) return false;
    final path = message.filePath;
    if (path == null) return false;
    final mime = message.text.toLowerCase();
    if (!mime.startsWith('video/')) return false;
    return File(path).existsSync();
  }

  @override
  ConsumerState<VideoBubble> createState() => _VideoBubbleState();
}

class _VideoBubbleState extends ConsumerState<VideoBubble> {
  VideoPoster? _poster;
  Animation<double>? _routeAnimation;
  String? _loadingPath;
  String? _posterPath;

  bool get _isCircle => VideoBubble.isCircle(widget.message);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadPoster();
  }

  @override
  void didUpdateWidget(VideoBubble old) {
    super.didUpdateWidget(old);
    if (old.message.filePath != widget.message.filePath) _loadPoster();
  }

  /// The first frame and the length, from memory when this run has seen the
  /// clip already, so a bubble scrolled back into view draws its picture on
  /// its first frame rather than a beat later.
  void _loadPoster() {
    final path = widget.message.filePath;
    if (path == null) return;
    // The Diagnostics experiment draws no media, so none is read either.
    if (TransitionProbe.instance.placeholderMedia.value) return;
    if (_posterPath != path) {
      _posterPath = path;
      _poster = null;
      _loadingPath = null;
    }
    _poster ??= VideoFrames.peek(path);
    if (_poster != null || _loadingPath == path) return;
    final animation = ModalRoute.of(context)?.animation;
    if (!identical(animation, _routeAnimation)) {
      _routeAnimation?.removeStatusListener(_routeStatus);
      _routeAnimation = animation;
      animation?.addStatusListener(_routeStatus);
    }
    // Memory hits are immediate; uncached native frame extraction waits until
    // the route is settled, instead of competing with the entrance animation.
    if (animation != null && animation.status != AnimationStatus.completed)
      return;
    _loadingPath = path;
    unawaited(
      VideoFrames.of(path).then((poster) {
        if (mounted && widget.message.filePath == path) {
          setState(() => _poster = poster);
        }
      }),
    );
  }

  void _routeStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) _loadPoster();
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_routeStatus);
    super.dispose();
  }

  Future<void> _tap() async {
    if (_isCircle) {
      await ref.read(voicePlaybackControllerProvider.notifier).toggleCircle(
            messageId: widget.message.id,
            path: widget.message.filePath!,
            chatId: widget.chatId ?? widget.message.chatId,
            chatTitle: playbackAuthor(
              context,
              ref,
              widget.message,
              chatId: widget.chatId,
            ),
            sentAt: widget.message.sentAt,
          );
      return;
    }
    // **Opened like a photo, not played in the bubble.** "Tap it and it just
    // opens, like a photo, and there a tap plays and pauses" was the ask, with
    // the three dots taken off. The viewer pages through the conversation's
    // photos and clips together.
    await Navigator.of(context).push(
      mediaRoute<void>(
        (_) => ChatMediaGalleryScreen(
          chatId: widget.chatId ?? widget.message.chatId,
          initialMessageId: widget.message.id,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => unawaited(_tap()),
      onLongPress: widget.onLongPress,
      child: _isCircle ? _circle() : _rectangle(),
    );
  }

  /// The first frame, filling its box, or nothing while it is being made.
  Widget _frame(double drawnWidth) {
    final frame = _poster?.frame;
    if (frame == null) return const SizedBox.shrink();
    // Diagnostics experiment: nothing decoded at all.
    if (TransitionProbe.instance.placeholderMedia.value) {
      return const ColoredBox(color: Color(0x33FFFFFF));
    }
    return Image.file(
      File(frame),
      fit: BoxFit.cover,
      // Decoded at the size it is drawn, like every photo in the chat.
      cacheWidth: (drawnWidth * MediaQuery.devicePixelRatioOf(context)).round(),
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }

  // ---- the round one ------------------------------------------------------

  Widget _circle() {
    // **Only this bubble's own share of the playback, and nothing when it is
    // not the one playing.**
    //
    // `ref.watch(provider)` woke every circle and every voice note in the
    // conversation on every position update — a dozen bubbles rebuilding many
    // times a second while one of them played, which is most of what "the
    // animations judder" was. Selected down to a record that is `null` unless
    // this is the current message: records compare by value, `null` equals
    // `null`, and a bubble that is not playing now rebuilds exactly zero times
    // for the whole of somebody else's circle.
    final tick = ref.watch(
      voicePlaybackControllerProvider.select(
        (s) => s.isCurrent(widget.message.id)
            ? (playing: s.playing, position: s.position, duration: s.duration)
            : null,
      ),
    );
    final current = tick != null;
    // Unpacked before anything reads them. A `bool ready` cannot carry the
    // record's promotion to the lines below it, and repeating `tick != null`
    // at each one to satisfy that is noise around three fields.
    final position = tick?.position ?? Duration.zero;
    final length = tick?.duration ?? Duration.zero;
    final started = tick?.playing ?? false;
    // Read, not watched: the widget needs the texture, and what decides when to
    // repaint came from the select above.
    final player = current
        ? ref.read(voicePlaybackControllerProvider.notifier).video
        : null;
    final ready = player != null && player.value.isInitialized;
    final playing = ready && started;
    final total = ready ? length : Duration.zero;
    final left = ready ? total - position : Duration.zero;
    final progress = ready && total.inMilliseconds > 0
        ? position.inMilliseconds / total.inMilliseconds
        : 0.0;

    // **Tapped, it grows to most of the screen, the way Telegram's does.**
    //
    // It used to grow by a quarter inside a slot that was always the playing
    // size, so the conversation never re-laid-out. The price of that was the
    // slot itself: a resting circle sat inside forty-eight points of nothing,
    // which pushed it away from its edge of the screen — reported as "move the
    // circles left, like Telegram" — and a growth that stayed that small read
    // as nothing happening when you tapped. Asked for plainly: bigger when
    // pressed, against the edge when not.
    //
    // A slot the size of the grown disc cannot be kept, it would leave more
    // empty space round a resting circle than the circle takes. So the slot
    // changes size, once per tap, over 260 ms. That is a relayout of one row
    // for a quarter of a second after a deliberate touch, not a cost paid while
    // scrolling or while playing — the playing frames repaint only the ring.
    final size = current
        ? VideoBubble.circleExpanded(MediaQuery.sizeOf(context).width)
        : VideoBubble.circleIdle;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      width: size,
      height: size,
      // The disc repaints with the ring and the countdown while it plays.
      // Its own layer, so that repaint does not drag the bubble, the row and
      // the conversation behind it into the same dirty rect.
      child: RepaintBoundary(
        child: _disc(
          ready: ready,
          current: current,
          playing: playing,
          player: player,
          progress: progress,
          left: left,
          total: total,
        ),
      ),
    );
  }

  Widget _disc({
    required bool ready,
    required bool current,
    required bool playing,
    required VideoPlayerController? player,
    required double progress,
    required Duration left,
    required Duration total,
  }) {
    return SizedBox.expand(
      child: CustomPaint(
        // The ring is the only chrome. No card, no border, no play button: a
        // circle is a circle, and the one thing worth drawing round it is how
        // much of it is left.
        foregroundPainter: _RingPainter(progress: playing ? progress : 0),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: ClipOval(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
                // **Its first frame, not a camera icon on black** - asked for
                // by name. Kept under the player until the clip has moved, so
                // the picture does not blink out while the decoder opens - and
                // not a frame longer: a circle plays at 60 fps, and an image
                // hidden under the video is still drawn on every one of them.
                if (!ready || progress <= 0)
                  _frame(
                    current
                        ? VideoBubble.circleExpanded(
                            MediaQuery.sizeOf(context).width,
                          )
                        : VideoBubble.circleIdle,
                  ),
                if (ready && player != null)
                  FittedBox(
                    // A circle is square and the camera is not, so the picture
                    // is filled rather than fitted.
                    fit: BoxFit.cover,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: player.value.size.width,
                      height: player.value.size.height,
                      child: VideoPlayer(player),
                    ),
                  ),
                if (current && !ready)
                  Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: AppColors.brandPrimary,
                      ),
                    ),
                  )
                else if (!ready && _poster?.frame == null)
                  Center(
                    child: Icon(
                      Icons.videocam_rounded,
                      size: 30,
                      color: Colors.white.withValues(alpha: 0.4),
                    ),
                  ),
                if (!widget.message.isMine && !widget.message.voicePlayed)
                  Positioned(
                    right: 26,
                    bottom: 18,
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.brandPrimary,
                      ),
                    ),
                  ),
                // How much is left to watch, in the corner where a voice note
                // puts its length.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 10,
                  child: Center(
                    child: _Chip(
                      label: ready
                          ? _clock(playing ? left : total)
                          : _poster?.length != null
                              ? _clock(_poster!.length!)
                              : _size(widget.message.fileBytes),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- the rectangular one ------------------------------------------------

  Widget _rectangle() {
    final aspect = _poster?.aspect ?? 16 / 9;
    final length = _poster?.length;

    // The same two numbers a photo is drawn at — the width asked of the photo
    // bubble's own helper, the height of [VideoBubble.rectangleHeight].
    final width = photoBubbleWidth(context);
    final height = VideoBubble.rectangleHeight(width, aspect);

    // No rounding of its own. The bubble clips to its own corners now that a
    // clip reaches them, and a second, tighter radius inside that one drew a
    // visible sliver of bubble in each corner - the same note [_ImagePayload]
    // carries, for the same reason.
    //
    // A photo with a play mark on it: the first frame, the length in the top
    // left corner the way Telegram puts it, the time in the bottom right (the
    // bubble puts that one on). No three dots - a long press has the actions,
    // and "remove the three dots on the video" was the report.
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: Colors.black.withValues(alpha: 0.55)),
          _frame(width),
          Center(
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.42),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.play_arrow_rounded,
                size: 30,
                color: Colors.white,
              ),
            ),
          ),
          Positioned(
            left: 8,
            top: 8,
            child: _Chip(
              label: length != null
                  ? _clock(length)
                  : _size(widget.message.fileBytes),
            ),
          ),
        ],
      ),
    );
  }

  static String _clock(Duration d) {
    final s = d.inSeconds.clamp(0, 359999);
    final m = s ~/ 60;
    return '$m:${(s % 60).toString().padLeft(2, '0')}';
  }

  static String _size(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// How much of a circle is left, drawn round it.
///
/// Only the part that has played, with no track behind it — a full grey ring
/// round every circle in the conversation is an outline on a shape that does
/// not need one.
class _RingPainter extends CustomPainter {
  const _RingPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(
        center: Offset(size.width / 2, size.height / 2),
        radius: size.width / 2 - 1.6,
      ),
      -math.pi / 2,
      math.pi * 2 * progress.clamp(0.0, 1.0),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: 0.9),
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress;
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
