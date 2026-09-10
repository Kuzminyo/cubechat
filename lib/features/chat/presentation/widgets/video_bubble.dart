import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../core/theme/colors.dart';
import '../../models/message.dart';
import '../../data/voice_playback_controller.dart';
import 'message_bubble.dart' show photoBubbleWidth;
import 'playback_author.dart';

/// Gallery clips play locally; circles share the voice-note player and island.
/// Playback starts only on tap and never loops. The shared circle survives
/// scrolling and navigation, while a gallery clip pauses when it leaves view.
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

  /// Resting, and playing.
  ///
  /// It grows when it starts. Not decoration: a circle at rest is one of many
  /// things in a scrolling column, and the one that is speaking should be the
  /// one your eye lands on. Telegram does the same and for the same reason.
  ///
  /// 200 and 248, up from 176 and 216. The gap between them is kept at a
  /// quarter rather than widened with them, because the growth has to read as
  /// emphasis and not as the layout jumping.
  ///
  /// The ceiling is the narrowest phone this runs on. 248 leaves about 70
  /// logical points beside the disc on a 320-point screen, which is enough for
  /// the row's margins and an avatar; past roughly 260 a circle starts to
  /// decide the width of the conversation rather than sit in it.
  static const double circleIdle = 200;
  static const double circlePlaying = 248;

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
  VideoPlayerController? _player;
  bool _loading = false;
  bool _failed = false;

  bool get _isCircle => VideoBubble.isCircle(widget.message);

  @override
  void dispose() {
    _player?.removeListener(_onTick);
    _player?.dispose();
    super.dispose();
  }

  void _onTick() {
    if (!mounted) return;
    setState(() {});
  }

  /// Open the file. Costs a platform decoder, so it happens once and only for
  /// a bubble that is actually on screen.
  Future<VideoPlayerController?> _open() async {
    if (_player != null) return _player;
    if (_loading || _failed) return null;
    setState(() => _loading = true);
    final player = VideoPlayerController.file(File(widget.message.filePath!));
    try {
      await player.initialize();
      if (!mounted) {
        await player.dispose();
        return null;
      }
      player.addListener(_onTick);
      // Explicit replay only.
      await player.setLooping(false);
      setState(() {
        _player = player;
        _loading = false;
      });
      return player;
    } catch (_) {
      await player.dispose();
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
      return null;
    }
  }

  Future<void> _onVisibility(VisibilityInfo info) async {
    // A circle belongs to the shared player and survives scrolling/leaving chat.
    if (_isCircle || !mounted || info.visibleFraction > 0.5) return;
    if (_player?.value.isPlaying ?? false) await _player?.pause();
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
    final player = _player ?? await _open();
    if (player == null) return;
    if (player.value.isPlaying) {
      await player.pause();
    } else {
      // A tap is the one thing that clears "already watched", which is what
      // makes it the way to see a circle a second time.
      if (player.value.position >= player.value.duration) {
        await player.seekTo(Duration.zero);
      }
      await player.play();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return VisibilityDetector(
      key: Key('video-${widget.message.id}'),
      onVisibilityChanged: (info) => unawaited(_onVisibility(info)),
      child: GestureDetector(
        onTap: () => unawaited(_tap()),
        onLongPress: widget.onLongPress,
        child: _isCircle ? _circle() : _rectangle(),
      ),
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

    // **The box does not change size; the disc inside it does.**
    //
    // It was an `AnimatedContainer` growing from 200 to 248, and a box that
    // changes size inside a scrolling list relayouts the row on every frame of
    // the 260 ms — the list, its padding and everything below the bubble, sixty
    // times, for a decoration. `AnimatedScale` is a transform applied when the
    // disc is painted: same movement on screen, no layout at all, and the
    // conversation underneath never shifts.
    //
    // The slot stays at the playing size and the resting disc sits inside it,
    // which also means the row does not jump when playback starts.
    return SizedBox(
      width: VideoBubble.circlePlaying,
      height: VideoBubble.circlePlaying,
      child: AnimatedScale(
        scale: playing ? 1 : VideoBubble.circleIdle / VideoBubble.circlePlaying,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
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
    return SizedBox(
      width: VideoBubble.circlePlaying,
      height: VideoBubble.circlePlaying,
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
                if (!ready)
                  Center(
                    child: (current && !ready)
                        ? SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              color: AppColors.brandPrimary,
                            ),
                          )
                        : Icon(
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
    final player = _player;
    final ready = player != null && player.value.isInitialized;
    final aspect = ready ? player.value.aspectRatio : 16 / 9;
    final position = ready ? player.value.position : Duration.zero;
    final total = ready ? player.value.duration : Duration.zero;

    // The same two numbers a photo is drawn at — the width asked of the photo
    // bubble's own helper, the height of [VideoBubble.rectangleHeight].
    final width = photoBubbleWidth(context);
    final height = VideoBubble.rectangleHeight(width, aspect);

    // No rounding of its own. The bubble clips to its own corners now that a
    // clip reaches them, and a second, tighter radius inside that one drew a
    // visible sliver of bubble in each corner — the same note [_ImagePayload]
    // carries, for the same reason.
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: Colors.black.withValues(alpha: 0.55)),
          if (ready)
            // Filled, not fitted: the box is the photo's shape, not the
            // camera's, and letterbox bars inside a bubble read as part of
            // the message.
            FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: player.value.size.width,
                height: player.value.size.height,
                child: VideoPlayer(player),
              ),
            ),
          if (!ready)
            Center(
              child: Icon(
                Icons.movie_rounded,
                size: 34,
                color: Colors.white.withValues(alpha: 0.35),
              ),
            ),
          // The button disappears while it is running, so a clip playing is
          // not covered by a control that says "play".
          if (!ready || !player.value.isPlaying)
            Center(
              child: _loading
                  ? SizedBox(
                      width: 34,
                      height: 34,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: AppColors.brandPrimary,
                      ),
                    )
                  : Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        size: 34,
                        color: Colors.white,
                      ),
                    ),
            ),
          if (ready)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: LinearProgressIndicator(
                value: total.inMilliseconds == 0
                    ? 0
                    : position.inMilliseconds / total.inMilliseconds,
                minHeight: 3,
                backgroundColor: Colors.white24,
                valueColor:
                    AlwaysStoppedAnimation<Color>(AppColors.brandPrimary),
              ),
            ),
          // Bottom left, because bottom right is where the bubble now floats
          // the clock and the ticks — the corner a photo puts them in.
          Positioned(
            left: 8,
            bottom: 10,
            child: _Chip(
              label: ready
                  ? _clock(total - position)
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
        ),
      ),
    );
  }
}
