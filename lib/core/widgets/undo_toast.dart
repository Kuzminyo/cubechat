import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/colors.dart';
import '../theme/glass.dart';

/// Something just happened that can still be taken back — "Chat deleted.
/// Undo" — with the seconds left counting down beside it.
///
/// A sibling of the glass toast rather than an option on it: that one ignores
/// pointers on purpose, so a confirmation never swallows a tap meant for the
/// screen under it, and this one exists to be tapped. Same pane, same place
/// above the nav bar, same rise into view.
///
/// One at a time. A second undoable action while the first is still counting
/// down settles the first — [onExpire] runs at once — rather than stacking two
/// countdowns or quietly forgetting the first one's commit.
class _UndoToastHost {
  static OverlayEntry? _entry;
  static Timer? _timer;
  static VoidCallback? _expire;

  static void show(
    OverlayState overlay, {
    required String message,
    required String undoLabel,
    required VoidCallback onUndo,
    required VoidCallback onExpire,
    required Duration duration,
  }) {
    _settle();

    final controller = _UndoToastController();
    late final OverlayEntry entry;
    var done = false;
    var removed = false;

    // Once. `OverlayEntry.mounted` stays true until the next build after a
    // removal, so it cannot be what decides whether to remove again — a toast
    // replaced mid-exit was being removed twice and asserting.
    void takeDown() {
      if (removed) return;
      removed = true;
      if (identical(_entry, entry)) _entry = null;
      entry.remove();
    }

    Future<void> finish({required bool undone, bool animate = true}) async {
      if (done) return;
      done = true;
      if (identical(_entry, entry)) {
        _timer?.cancel();
        _timer = null;
        _expire = null;
      }
      if (undone) {
        onUndo();
      } else {
        onExpire();
      }
      if (animate) await controller.reverse();
      takeDown();
    }

    entry = OverlayEntry(
      builder: (_) => _UndoToast(
        message: message,
        undoLabel: undoLabel,
        duration: duration,
        controller: controller,
        onUndo: () => unawaited(finish(undone: true)),
      ),
    );
    _entry = entry;
    // Replaced by the next one: committed and gone at once, no exit to wait on.
    _expire = () => unawaited(finish(undone: false, animate: false));
    overlay.insert(entry);
    unawaited(HapticFeedback.selectionClick());
    _timer = Timer(duration, () => unawaited(finish(undone: false)));
  }

  /// The toast showing, if any, runs out now: its action is committed and it
  /// is taken down without waiting for its animation.
  static void _settle() {
    final expire = _expire;
    _timer?.cancel();
    _timer = null;
    _expire = null;
    expire?.call();
    _entry = null;
  }
}

class _UndoToastController {
  Future<void> Function()? _reverse;
  Future<void> reverse() async => _reverse?.call();
}

class _UndoToast extends StatefulWidget {
  const _UndoToast({
    required this.message,
    required this.undoLabel,
    required this.duration,
    required this.controller,
    required this.onUndo,
  });

  final String message;
  final String undoLabel;
  final Duration duration;
  final _UndoToastController controller;
  final VoidCallback onUndo;

  @override
  State<_UndoToast> createState() => _UndoToastState();
}

class _UndoToastState extends State<_UndoToast> with TickerProviderStateMixin {
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    reverseDuration: const Duration(milliseconds: 180),
  );

  /// Runs once over the whole countdown; the ring and the number both read it.
  late final AnimationController _countdown =
      AnimationController(vsync: this, duration: widget.duration);

  @override
  void initState() {
    super.initState();
    widget.controller._reverse = () async {
      if (mounted) await _enter.reverse();
    };
    _enter.forward();
    _countdown.forward();
  }

  @override
  void dispose() {
    _enter.dispose();
    _countdown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(22);
    final curve = CurvedAnimation(parent: _enter, curve: Curves.easeOutCubic);
    return Positioned(
      left: 16,
      right: 16,
      // Where the glass toast sits: clear of the nav bar and the composer.
      bottom: MediaQuery.of(context).viewInsets.bottom +
          MediaQuery.of(context).padding.bottom +
          96,
      child: Material(
        type: MaterialType.transparency,
        child: FadeTransition(
          opacity: curve,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.6),
              end: Offset.zero,
            ).animate(curve),
            child: Semantics(
              liveRegion: true,
              child: ClipRRect(
                borderRadius: radius,
                child: GlassBlur(
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          AppColors.glass(0.07),
                          AppColors.pane(0.62),
                        ],
                      ),
                      borderRadius: radius,
                      border: Border.all(color: AppColors.glass(0.16)),
                    ),
                    child: Row(
                      children: [
                        RepaintBoundary(
                          child: _Countdown(
                            progress: _countdown,
                            total: widget.duration,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            widget.message,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textOnGlass,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: widget.onUndo,
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.brandPrimary,
                            minimumSize: const Size(44, 44),
                          ),
                          icon: const Icon(Icons.undo_rounded, size: 18),
                          label: Text(
                            widget.undoLabel,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The seconds left, inside a ring that empties with them.
class _Countdown extends StatelessWidget {
  const _Countdown({required this.progress, required this.total});

  final Animation<double> progress;
  final Duration total;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      builder: (context, _) {
        final left = 1 - progress.value;
        final seconds = (left * total.inMilliseconds / 1000).ceil();
        return SizedBox.square(
          dimension: 28,
          child: CustomPaint(
            painter: _RingPainter(
              left: left,
              color: AppColors.textOnGlass,
              track: AppColors.glass(0.16),
            ),
            child: Center(
              child: Text(
                '$seconds',
                style: TextStyle(
                  color: AppColors.textOnGlass,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.left, required this.color, required this.track});

  final double left;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 2.2;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track,
    );
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * left,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.left != left || old.color != color || old.track != track;
}

/// Show "[message] · Undo" for [duration], counting down.
///
/// [onUndo] runs if Undo is tapped; otherwise [onExpire] runs when the time is
/// up, or at once if another undo toast replaces this one. Exactly one of the
/// two runs, exactly once.
///
/// Takes the overlay rather than a context, because the thing being undone is
/// usually what the context belonged to: a deleted row is out of the tree by
/// the time anything could look an overlay up from it.
void showUndoToast(
  OverlayState overlay, {
  required String message,
  required String undoLabel,
  required VoidCallback onUndo,
  required VoidCallback onExpire,
  Duration duration = const Duration(seconds: 5),
}) =>
    _UndoToastHost.show(
      overlay,
      message: message,
      undoLabel: undoLabel,
      onUndo: onUndo,
      onExpire: onExpire,
      duration: duration,
    );
