import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../models/message.dart';

/// Renders a voice message: play/pause button + progress bar + duration.
///
/// Each instance owns its own [AudioPlayer]. Switching to the next bubble
/// stops the previous one — there's no global single-player coordinator yet,
/// but tapping a new bubble while another is playing seamlessly cuts the
/// first because the first widget unwinds its `_position` subscription when
/// it sees `isPlaying == false`.
class VoiceBubble extends StatefulWidget {
  const VoiceBubble({super.key, required this.message});

  final Message message;

  @override
  State<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<VoiceBubble> {
  final _player = AudioPlayer();
  Duration _position = Duration.zero;
  Duration _total = Duration.zero;
  bool _playing = false;

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<void>? _completeSub;

  @override
  void initState() {
    super.initState();
    final ms = widget.message.audioDurationMs;
    if (ms != null) {
      _total = Duration(milliseconds: ms);
    }
    _posSub = _player.onPositionChanged.listen((d) {
      if (mounted) setState(() => _position = d);
    });
    _durSub = _player.onDurationChanged.listen((d) {
      if (mounted && d > Duration.zero) setState(() => _total = d);
    });
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _position = Duration.zero;
        });
      }
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _completeSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final path = widget.message.audioPath;
    if (path == null || !File(path).existsSync()) return;
    if (_playing) {
      await _player.pause();
      if (mounted) setState(() => _playing = false);
    } else {
      await _player.play(DeviceFileSource(path));
      if (mounted) setState(() => _playing = true);
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final hasFile = widget.message.audioPath != null &&
        File(widget.message.audioPath!).existsSync();
    final total = _total > Duration.zero
        ? _total
        : Duration(milliseconds: widget.message.audioDurationMs ?? 0);
    final progress = total > Duration.zero
        ? (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return SizedBox(
      width: 200,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: hasFile ? _toggle : null,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hasFile
                    ? AppColors.brandPrimary.withValues(alpha: 0.25)
                    : Colors.white.withValues(alpha: 0.08),
              ),
              child: Icon(
                _playing ? Icons.pause : Icons.play_arrow,
                color: hasFile
                    ? AppColors.textOnGlass
                    : AppColors.textOnGlassFaint,
                size: 22,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: hasFile ? progress : null,
                    minHeight: 4,
                    backgroundColor: Colors.white.withValues(alpha: 0.12),
                    valueColor: AlwaysStoppedAnimation(
                      AppColors.brandPrimary,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _fmt(_playing ? _position : total),
                  style: TextStyle(
                    color: AppColors.textOnGlassDim,
                    fontSize: 11,
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
