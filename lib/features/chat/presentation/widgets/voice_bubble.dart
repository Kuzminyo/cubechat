import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/colors.dart';
import '../../data/voice_playback_controller.dart';
import '../../models/message.dart';

/// Renders a voice message: play/pause button + progress bar + duration.
///
/// Owns no player. It used to own one each, disposed with the widget — which
/// meant scrolling the bubble off screen, or leaving the chat, cut the audio
/// mid-sentence. Playback lives in [voicePlaybackControllerProvider] now and
/// outlives every screen; this widget only shows the state of the one message
/// it represents, and hands taps on.
class VoiceBubble extends ConsumerStatefulWidget {
  const VoiceBubble({
    super.key,
    required this.message,
    this.chatTitle,
  });

  final Message message;

  /// Whose voice this is, for the mini player's caption. Falls back to the
  /// chat id when a caller has nothing better.
  final String? chatTitle;

  @override
  ConsumerState<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends ConsumerState<VoiceBubble> {
  /// Fraction (0..1) of the bar the user is currently dragging the thumb
  /// to. Non-null = drag in progress; the actual seek commits on release.
  /// While dragging we render the thumb at this position so the UI feels
  /// responsive even when the underlying decoder hasn't seeked yet.
  double? _scrubbing;

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final playback = ref.watch(voicePlaybackControllerProvider);
    final isCurrent = playback.isCurrent(widget.message.id);
    final hasFile = widget.message.audioPath != null &&
        File(widget.message.audioPath!).existsSync();

    final declared =
        Duration(milliseconds: widget.message.audioDurationMs ?? 0);
    // The decoder's own duration is better than the declared one, but only
    // exists for the message actually loaded.
    final total = isCurrent && playback.duration > Duration.zero
        ? playback.duration
        : declared;
    final position = isCurrent ? playback.position : Duration.zero;
    final playing = isCurrent && playback.playing;
    final progress = total > Duration.zero
        ? (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    Future<void> toggle() => ref
        .read(voicePlaybackControllerProvider.notifier)
        .toggle(
          messageId: widget.message.id,
          path: widget.message.audioPath!,
          chatId: widget.message.chatId,
          chatTitle: widget.chatTitle ?? widget.message.chatId,
          knownDuration: declared > Duration.zero ? declared : null,
        );

    return SizedBox(
      width: 200,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: hasFile ? toggle : null,
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
                playing ? Icons.pause : Icons.play_arrow,
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
                _ScrubBar(
                  progress: _scrubbing ?? progress,
                  enabled: hasFile && total > Duration.zero,
                  onSeekStart: (frac) => setState(() => _scrubbing = frac),
                  onSeekUpdate: (frac) => setState(() => _scrubbing = frac),
                  onSeekCommit: (frac) async {
                    setState(() => _scrubbing = null);
                    // Seeking a message that is not the current one has nothing
                    // to seek: start it there instead.
                    if (!isCurrent) await toggle();
                    await ref
                        .read(voicePlaybackControllerProvider.notifier)
                        .seekFraction(frac);
                  },
                ),
                const SizedBox(height: 4),
                Text(
                  _fmt(playing
                      ? position
                      : (_scrubbing == null
                          ? total
                          : Duration(
                              milliseconds:
                                  (total.inMilliseconds * _scrubbing!).round(),
                            ))),
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

/// Tappable + draggable playback scrubber. Renders a thin progress bar
/// with a small thumb at the current position; horizontal-drag/tap on the
/// bar reports the new fractional position via the seek callbacks. The
/// parent owns the actual seek + UI state.
class _ScrubBar extends StatelessWidget {
  const _ScrubBar({
    required this.progress,
    required this.enabled,
    required this.onSeekStart,
    required this.onSeekUpdate,
    required this.onSeekCommit,
  });

  final double progress;
  final bool enabled;
  final ValueChanged<double> onSeekStart;
  final ValueChanged<double> onSeekUpdate;
  final ValueChanged<double> onSeekCommit;

  double _fracFor(double localX, double width) {
    if (width <= 0) return 0;
    return (localX / width).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: enabled
              ? (d) => onSeekStart(_fracFor(d.localPosition.dx, width))
              : null,
          onHorizontalDragUpdate: enabled
              ? (d) => onSeekUpdate(_fracFor(d.localPosition.dx, width))
              : null,
          onHorizontalDragEnd:
              enabled ? (_) => onSeekCommit(progress.clamp(0.0, 1.0)) : null,
          onTapDown: enabled
              ? (d) => onSeekStart(_fracFor(d.localPosition.dx, width))
              : null,
          onTapUp: enabled
              ? (d) => onSeekCommit(_fracFor(d.localPosition.dx, width))
              : null,
          // Hit area is taller than the visual bar so it's easy to grab.
          child: SizedBox(
            height: 16,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: progress.clamp(0.0, 1.0),
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.brandPrimary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Positioned(
                  left: (width * progress.clamp(0.0, 1.0)) - 6,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: enabled
                          ? AppColors.brandPrimary
                          : AppColors.textOnGlassFaint,
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.4)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
