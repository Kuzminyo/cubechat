import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../../core/theme/colors.dart';
import '../../models/message.dart';

/// Telegram-style "circle video" bubble — square aspect, clip-oval into a
/// disc. Lazy-loads the video on first build, tap toggles play/pause.
///
/// Each bubble owns its own [VideoPlayerController]. We don't try to
/// coordinate across bubbles (no global single-player), so tapping a
/// second one while the first is playing leaves both playing — quirky but
/// good enough for a first pass.
class CircleVideoBubble extends StatefulWidget {
  const CircleVideoBubble({super.key, required this.message, this.size = 180});

  final Message message;
  final double size;

  @override
  State<CircleVideoBubble> createState() => _CircleVideoBubbleState();
}

class _CircleVideoBubbleState extends State<CircleVideoBubble> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _initError = false;

  @override
  void initState() {
    super.initState();
    _tryInit();
  }

  Future<void> _tryInit() async {
    final path = widget.message.videoPath;
    if (path == null || !File(path).existsSync()) return;
    final c = VideoPlayerController.file(File(path));
    try {
      await c.initialize();
      await c.setVolume(1.0);
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _controller = c;
        _initialized = true;
      });
    } catch (e) {
      debugPrint('CircleVideoBubble init failed: $e');
      await c.dispose();
      if (mounted) setState(() => _initError = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      if (c.value.position >= c.value.duration) {
        await c.seekTo(Duration.zero);
      }
      await c.play();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final hasFile = widget.message.videoPath != null &&
        File(widget.message.videoPath!).existsSync();

    Widget core;
    if (_initError || !hasFile) {
      core = _placeholder(Icons.videocam_off_outlined);
    } else if (!_initialized) {
      core = _placeholder(
        widget.message.status == MessageStatus.sending
            ? Icons.upload_outlined
            : Icons.movie_outlined,
        showSpinner: widget.message.status == MessageStatus.sending,
      );
    } else {
      final c = _controller!;
      core = Stack(
        alignment: Alignment.center,
        children: [
          FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: c.value.size.width,
              height: c.value.size.height,
              child: VideoPlayer(c),
            ),
          ),
          if (!c.value.isPlaying)
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: 0.35),
              ),
              padding: const EdgeInsets.all(10),
              child: Icon(
                Icons.play_arrow,
                color: Colors.white.withValues(alpha: 0.95),
                size: 28,
              ),
            ),
        ],
      );
    }

    return GestureDetector(
      onTap: _initialized ? _toggle : null,
      child: SizedBox(
        width: size,
        height: size,
        child: ClipOval(child: core),
      ),
    );
  }

  Widget _placeholder(IconData icon, {bool showSpinner = false}) {
    return Container(
      color: Colors.white.withValues(alpha: 0.06),
      child: Center(
        child: showSpinner
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.brandPrimary,
                ),
              )
            : Icon(icon, color: AppColors.textOnGlassDim, size: 28),
      ),
    );
  }
}
