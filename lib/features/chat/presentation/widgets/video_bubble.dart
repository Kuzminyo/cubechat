import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../../core/theme/colors.dart';
import '../../models/message.dart';

/// A clip that plays where it sits.
///
/// A video arrives through the file transport and used to be drawn as a row
/// with a name and a size — a document that happened to be a film. Opening it
/// meant handing it to whatever the phone considers a video player, leaving
/// the conversation to do it.
///
/// **No player is built until the clip is tapped.** `VideoPlayerController`
/// holds a platform decoder, and a conversation with a dozen clips in it would
/// otherwise hold a dozen of them open while somebody scrolls past — the exact
/// shape of cost this codebase has taken out twice already (uncapped image
/// decodes, ungrouped blurs). The first tap loads and plays; until then this
/// is a card with a play button on it, which costs nothing.
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
  ///
  /// Versioned, so a later shape for these can be told from this one without
  /// guessing.
  static const String circleFileName = 'cubechat-circle-v1.mp4';

  /// Drawn round and square rather than as a rectangle in a card.
  static bool isCircle(Message message) =>
      message.fileName == circleFileName;

  /// How wide a circle is drawn.
  static const double circleDiameter = 200;

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
  Object? _failed;

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final existing = _player;
    if (existing != null) {
      // Second tap: pause or carry on. A clip that restarts from the top every
      // time it is touched cannot be paused to look at something.
      if (existing.value.isPlaying) {
        await existing.pause();
      } else {
        await existing.play();
      }
      setState(() {});
      return;
    }
    if (_loading) return;
    setState(() {
      _loading = true;
      _failed = null;
    });
    final player = VideoPlayerController.file(File(widget.message.filePath!));
    try {
      await player.initialize();
      if (!mounted) {
        await player.dispose();
        return;
      }
      // Rebuilds on the position, which is what draws the progress line. The
      // listener goes with the controller, so nothing ticks once this bubble
      // is gone.
      player.addListener(_onTick);
      await player.setLooping(false);
      await player.play();
      setState(() {
        _player = player;
        _loading = false;
      });
    } catch (e) {
      await player.dispose();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = e;
      });
    }
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final ready = player != null && player.value.isInitialized;
    final aspect = ready ? player.value.aspectRatio : 16 / 9;
    final position = ready ? player.value.position : Duration.zero;
    final total = ready ? player.value.duration : Duration.zero;

    final round = VideoBubble.isCircle(widget.message);
    return GestureDetector(
      onTap: _start,
      onLongPress: widget.onLongPress,
      child: ClipRRect(
        // A circle is a circle. Clipped rather than masked so the progress
        // line and the chip below are clipped with the picture, which is what
        // keeps it reading as one object.
        borderRadius: BorderRadius.circular(
          round ? VideoBubble.circleDiameter / 2 : 14,
        ),
        child: SizedBox(
          width: round ? VideoBubble.circleDiameter : VideoBubble.width,
          child: AspectRatio(
            aspectRatio: round ? 1 : (aspect <= 0 ? 16 / 9 : aspect),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: Colors.black.withValues(alpha: 0.55)),
                if (ready)
                  // A circle is square and the camera is not, so the picture
                  // is filled rather than fitted — a letterboxed round video
                  // is a small rectangle inside a black disc.
                  round
                      ? FittedBox(
                          fit: BoxFit.cover,
                          clipBehavior: Clip.hardEdge,
                          child: SizedBox(
                            width: player.value.size.width,
                            height: player.value.size.height,
                            child: VideoPlayer(player),
                          ),
                        )
                      : VideoPlayer(player),
                if (!ready)
                  Center(
                    child: Icon(
                      Icons.movie_rounded,
                      size: 34,
                      color: Colors.white.withValues(alpha: 0.35),
                    ),
                  ),
                // The button disappears while it is running, so a clip playing
                // is not covered by a control that says "play".
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
                    label: _failed != null
                        ? '—'
                        : ready
                            ? _clock(total - position)
                            : _size(widget.message.fileBytes),
                  ),
                ),
              ],
            ),
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

class _Chip extends StatelessWidget {
  const _Chip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
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
