import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../../../l10n/app_localizations.dart';
import 'chat_input.dart';

/// A recorded voice note, held back from sending so the range can be picked.
@immutable
class PendingVoice {
  const PendingVoice({
    required this.path,
    required this.durationMs,
    required this.envelope,
  });

  final String path;
  final int durationMs;

  /// Loudness per sample across the whole recording, 0..1.
  final List<double> envelope;
}

/// Review island for a locked recording: the waveform, a handle at each end,
/// and preview playback of exactly what will be sent.
///
/// It appears only for a *locked* recording. A held press that is released
/// still sends at once — that gesture's whole point is speed, and interposing
/// an editor would make the common case slower to serve the rare one.
///
/// The handles select a range; nothing is cut here. The actual cut happens on
/// send, natively, and is allowed to fail — see `AudioTrimmer`.
class VoiceTrimBar extends StatefulWidget {
  const VoiceTrimBar({
    super.key,
    required this.pending,
    required this.onCancel,
    required this.onSend,
  });

  final PendingVoice pending;
  final VoidCallback onCancel;

  /// Called with the chosen range, in milliseconds from the start.
  final void Function(int startMs, int endMs) onSend;

  @override
  State<VoiceTrimBar> createState() => _VoiceTrimBarState();
}

class _VoiceTrimBarState extends State<VoiceTrimBar> {
  final _player = AudioPlayer();
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<void>? _doneSub;

  double _start = 0;
  double _end = 1;
  bool _playing = false;
  Duration _position = Duration.zero;

  /// Shortest selection the trimmer will act on, as a fraction of the clip.
  double get _minSpan {
    final d = widget.pending.durationMs;
    if (d <= 0) return 1;
    return (500 / d).clamp(0.02, 1.0);
  }

  int get _startMs => (_start * widget.pending.durationMs).round();
  int get _endMs => (_end * widget.pending.durationMs).round();

  @override
  void initState() {
    super.initState();
    _posSub = _player.onPositionChanged.listen((p) {
      if (!mounted) return;
      // Stop at the out point rather than playing the tail the user just cut.
      if (p.inMilliseconds >= _endMs) {
        unawaited(_player.pause());
        setState(() {
          _playing = false;
          _position = Duration(milliseconds: _startMs);
        });
        return;
      }
      setState(() => _position = p);
    });
    _doneSub = _player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() => _playing = false);
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _doneSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    if (_playing) {
      await _player.pause();
      if (mounted) setState(() => _playing = false);
      return;
    }
    await _player.play(DeviceFileSource(widget.pending.path));
    await _player.seek(Duration(milliseconds: _startMs));
    if (mounted) setState(() => _playing = true);
  }

  /// Playback has to restart inside the new range when a handle moves past it.
  void _handleMoved() {
    if (!_playing) return;
    final ms = _position.inMilliseconds;
    if (ms < _startMs || ms > _endMs) {
      unawaited(_player.seek(Duration(milliseconds: _startMs)));
    }
  }

  String _fmt(int ms) {
    final total = (ms / 1000).round();
    final m = total ~/ 60;
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final selectedMs = (_endMs - _startMs).clamp(0, widget.pending.durationMs);

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: MessageIslandGlass(
        borderRadius: 24,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: t.voiceTrimDiscard,
                  icon: Icon(Icons.delete_outline,
                      color: AppColors.textOnGlassDim, size: 20),
                  onPressed: widget.onCancel,
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: _playing ? t.voiceTrimPause : t.voiceTrimPlay,
                  icon: Icon(
                    _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: AppColors.brandPrimary,
                    size: 24,
                  ),
                  onPressed: _togglePlay,
                ),
                Expanded(
                  child: Text(
                    t.voiceTrimSelection(_fmt(selectedMs)),
                    style: TextStyle(
                      color: AppColors.textOnGlassDim,
                      fontSize: 12,
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: t.chatSend,
                  icon: Icon(Icons.send_rounded,
                      color: AppColors.brandPrimary, size: 22),
                  onPressed: () => widget.onSend(_startMs, _endMs),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 56,
              child: _TrimTrack(
                envelope: widget.pending.envelope,
                start: _start,
                end: _end,
                minSpan: _minSpan,
                progress: widget.pending.durationMs <= 0
                    ? null
                    : _position.inMilliseconds / widget.pending.durationMs,
                onChanged: (s, e) {
                  setState(() {
                    _start = s;
                    _end = e;
                  });
                  _handleMoved();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The waveform with its two draggable ends. Everything outside the selection
/// is dimmed, so what will be sent is legible without reading the numbers.
class _TrimTrack extends StatefulWidget {
  const _TrimTrack({
    required this.envelope,
    required this.start,
    required this.end,
    required this.minSpan,
    required this.onChanged,
    this.progress,
  });

  final List<double> envelope;
  final double start;
  final double end;
  final double minSpan;
  final double? progress;
  final void Function(double start, double end) onChanged;

  @override
  State<_TrimTrack> createState() => _TrimTrackState();
}

class _TrimTrackState extends State<_TrimTrack> {
  /// Which handle the current drag owns. Decided once on touch-down, so a
  /// finger that crosses the other handle mid-drag doesn't hand over to it.
  _Handle? _dragging;

  static const double _handleWidth = 14;

  double _fractionFor(double dx, double width) =>
      width <= 0 ? 0 : (dx / width).clamp(0.0, 1.0);

  void _down(Offset local, double width) {
    final f = _fractionFor(local.dx, width);
    final toStart = (f - widget.start).abs();
    final toEnd = (f - widget.end).abs();
    _dragging = toStart <= toEnd ? _Handle.start : _Handle.end;
    _update(local, width);
  }

  void _update(Offset local, double width) {
    final f = _fractionFor(local.dx, width);
    if (_dragging == _Handle.start) {
      widget.onChanged(
        f.clamp(0.0, widget.end - widget.minSpan).toDouble(),
        widget.end,
      );
    } else if (_dragging == _Handle.end) {
      widget.onChanged(
        widget.start,
        f.clamp(widget.start + widget.minSpan, 1.0).toDouble(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragDown: (d) => _down(d.localPosition, width),
          onHorizontalDragUpdate: (d) => _update(d.localPosition, width),
          onHorizontalDragEnd: (_) => _dragging = null,
          onHorizontalDragCancel: () => _dragging = null,
          child: CustomPaint(
            size: Size(width, constraints.maxHeight),
            painter: _TrimPainter(
              envelope: widget.envelope,
              start: widget.start,
              end: widget.end,
              progress: widget.progress,
              handleWidth: _handleWidth,
            ),
          ),
        );
      },
    );
  }
}

enum _Handle { start, end }

class _TrimPainter extends CustomPainter {
  _TrimPainter({
    required this.envelope,
    required this.start,
    required this.end,
    required this.handleWidth,
    this.progress,
  });

  final List<double> envelope;
  final double start;
  final double end;
  final double? progress;
  final double handleWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    const barWidth = 3.0;
    const gap = 2.0;
    final slot = barWidth + gap;
    final bars = (size.width / slot).floor().clamp(1, 4096);

    final inside = Paint()..color = AppColors.brandPrimary;
    final outside = Paint()..color = Colors.white.withValues(alpha: 0.16);

    for (var i = 0; i < bars; i++) {
      final f = bars <= 1 ? 0.0 : i / (bars - 1);
      final level = _sample(f);
      final h = (level * (size.height - 8)).clamp(3.0, size.height - 8);
      final x = i * slot;
      final selected = f >= start && f <= end;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, mid - h / 2, barWidth, h),
          const Radius.circular(1.5),
        ),
        selected ? inside : outside,
      );
    }

    // Playhead, drawn only while it is inside the selection.
    final p = progress;
    if (p != null && p >= start && p <= end) {
      canvas.drawRect(
        Rect.fromLTWH(p * size.width - 1, 4, 2, size.height - 8),
        Paint()..color = Colors.white.withValues(alpha: 0.85),
      );
    }

    _drawHandle(canvas, size, start);
    _drawHandle(canvas, size, end);
  }

  void _drawHandle(Canvas canvas, Size size, double at) {
    final cx =
        (at * size.width).clamp(handleWidth / 2, size.width - handleWidth / 2);
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(cx - handleWidth / 2, 0, handleWidth, size.height),
      const Radius.circular(7),
    );
    canvas.drawRRect(rect, Paint()..color = AppColors.brandPrimary);
    // Grip line, so the handle reads as draggable rather than as a marker.
    canvas.drawRect(
      Rect.fromLTWH(cx - 1, size.height * 0.32, 2, size.height * 0.36),
      Paint()..color = Colors.white.withValues(alpha: 0.9),
    );
  }

  /// Envelope sampled at [f], with a flat fallback when the recorder produced
  /// no amplitude events (a very short clip, or a device that reports none).
  double _sample(double f) {
    if (envelope.isEmpty) return 0.35;
    final i = (f * (envelope.length - 1)).round().clamp(0, envelope.length - 1);
    return envelope[i];
  }

  @override
  bool shouldRepaint(_TrimPainter old) =>
      old.start != start ||
      old.end != end ||
      old.progress != progress ||
      !identical(old.envelope, envelope);
}
