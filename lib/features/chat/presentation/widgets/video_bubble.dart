import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../core/theme/colors.dart';
import '../../models/message.dart';

/// A clip that plays where it sits.
///
/// A video arrives through the file transport and used to be drawn as a row
/// with a name and a size — a document that happened to be a film. Opening it
/// meant handing it to whatever the phone considers a video player, leaving
/// the conversation to do it.
///
/// Two shapes, one widget. A clip from the gallery is a rectangle you press to
/// start. A circle is round, starts on its own when it comes into view, grows
/// while it plays, and stops when you scroll past — which is what everyone who
/// has used one expects of them, and is only possible because we know which
/// one is actually on screen.
class VideoBubble extends StatefulWidget {
  const VideoBubble({
    super.key,
    required this.message,
    this.onLongPress,
  });

  final Message message;
  final VoidCallback? onLongPress;

  /// The width a clip is drawn at, matching the photo bubble beside it.
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
  static const String circleFileName = 'cubechat-circle-v1.mp4';

  /// Drawn round and square rather than as a rectangle in a card.
  static bool isCircle(Message message) =>
      message.fileName == circleFileName;

  /// Resting, and playing.
  ///
  /// It grows when it starts. Not decoration: a circle at rest is one of many
  /// things in a scrolling column, and the one that is speaking should be the
  /// one your eye lands on. Telegram does the same and for the same reason.
  static const double circleIdle = 176;
  static const double circlePlaying = 216;

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
  State<VideoBubble> createState() => _VideoBubbleState();
}

class _VideoBubbleState extends State<VideoBubble> {
  VideoPlayerController? _player;
  bool _loading = false;
  bool _failed = false;

  /// Paused by a finger rather than by scrolling away.
  ///
  /// Without this a circle you deliberately paused starts itself again on the
  /// next scroll tick, because coming back into view is indistinguishable from
  /// arriving in view for the first time.
  bool _pausedByHand = false;

  /// It has already played all the way through in this session.
  ///
  /// A circle used to loop — `setLooping(true)` and a listener that seeked
  /// back to zero at the end — so opening a chat left one spinning and talking
  /// until you scrolled it off the screen. Autoplay is still right: it is what
  /// every messenger with circles does, and the point of a circle is that you
  /// do not have to press anything. Playing *again* is not. Once it has
  /// finished, it stays finished until somebody taps it.
  bool _playedThrough = false;

  bool get _isCircle => VideoBubble.isCircle(widget.message);

  @override
  void dispose() {
    _player?.removeListener(_onTick);
    _player?.dispose();
    super.dispose();
  }

  void _onTick() {
    if (!mounted) return;
    final player = _player;
    // Reaching the end is the end. Rewound so the next tap starts from the
    // beginning rather than from a frame that is already over, and marked so
    // scrolling it back into view does not start it again.
    if (_isCircle &&
        player != null &&
        player.value.isInitialized &&
        !_playedThrough &&
        player.value.position >= player.value.duration &&
        player.value.duration > Duration.zero) {
      _playedThrough = true;
      unawaited(player.pause());
      unawaited(player.seekTo(Duration.zero));
    }
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
      // Never. A circle plays once; see [_playedThrough].
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

  /// Scrolled into or out of view.
  ///
  /// Circles only. A clip from the gallery is a thing you decide to watch;
  /// starting one because it drifted past would be a video playing at somebody
  /// in the middle of reading.
  Future<void> _onVisibility(VisibilityInfo info) async {
    if (!_isCircle || !mounted) return;
    // Half of it, so a circle half off the top of the screen does not claim
    // the sound from the one that has just arrived below it.
    final visible = info.visibleFraction > 0.5;
    if (visible) {
      // Two ways of having stopped that both mean "do not start again": a
      // finger on it, and having already run to the end once.
      if (_pausedByHand || _playedThrough) return;
      final player = await _open();
      if (player != null && !player.value.isPlaying) await player.play();
    } else {
      final player = _player;
      if (player != null && player.value.isPlaying) await player.pause();
      // Off screen is not a decision, so coming back starts it again — unless
      // it has already been watched, which is.
      _pausedByHand = false;
    }
  }

  Future<void> _tap() async {
    final player = _player ?? await _open();
    if (player == null) return;
    if (player.value.isPlaying) {
      _pausedByHand = true;
      await player.pause();
    } else {
      // A tap is the one thing that overrides both stops, which is what makes
      // it the way to watch a circle a second time.
      _pausedByHand = false;
      _playedThrough = false;
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
    final player = _player;
    final ready = player != null && player.value.isInitialized;
    final playing = ready && player.value.isPlaying;
    final total = ready ? player.value.duration : Duration.zero;
    final left = ready ? total - player.value.position : Duration.zero;
    final progress = ready && total.inMilliseconds > 0
        ? player.value.position.inMilliseconds / total.inMilliseconds
        : 0.0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      width: playing ? VideoBubble.circlePlaying : VideoBubble.circleIdle,
      height: playing ? VideoBubble.circlePlaying : VideoBubble.circleIdle,
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
                if (ready)
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
                    child: _loading
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

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: VideoBubble.width,
        child: AspectRatio(
          aspectRatio: aspect <= 0 ? 16 / 9 : aspect,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: Colors.black.withValues(alpha: 0.55)),
              if (ready) VideoPlayer(player),
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
        ),
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
