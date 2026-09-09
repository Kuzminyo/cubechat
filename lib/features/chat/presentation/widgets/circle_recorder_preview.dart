import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../data/circle_recorder.dart';

/// What a circle looks like while it is being recorded.
///
/// The whole screen, not a band above the composer. A circle is a camera
/// pointed at your face — you are looking at yourself, not at the
/// conversation — so the conversation goes behind glass and the circle takes
/// the middle. The composer strip below keeps the timer, the slide-to-cancel
/// and the send button, because the mechanics are the voice recorder's and
/// changing them would mean learning the same gesture twice.
///
/// Shown through an [OverlayEntry] rather than in the composer's own column:
/// that column is what the conversation's bottom padding is measured off, and
/// a 280-point preview appearing inside it would shove the whole chat upward
/// while a finger is held down on the button that started it.
class CircleRecorderPreview extends StatelessWidget {
  const CircleRecorderPreview({
    super.key,
    required this.recorder,
    required this.hint,
    required this.locked,
  });

  final CircleRecorder recorder;

  /// One line under the circle: what letting go does.
  final String hint;

  /// True once the press has ended and the recording carries on by itself.
  final bool locked;

  /// Light, not heavy. The conversation behind should still be recognisable as
  /// the chat you are in — the blur says "later", not "gone". Deliberately
  /// below [AppBlur.sigma]: this one runs over a live camera preview, which is
  /// the most expensive thing on the screen already.
  static const double backdropBlur = 9;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // Big enough to see a face in, and clear of the composer underneath.
    final diameter = math.min(media.size.width * 0.66, 290.0);
    return AnimatedBuilder(
      animation: recorder,
      builder: (context, _) {
        final camera = recorder.camera;
        final ready = recorder.isReady && camera != null;
        return Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(
                    sigmaX: backdropBlur,
                    sigmaY: backdropBlur,
                  ),
                  child: ColoredBox(
                    color: AppColors.bgDeep.withValues(alpha: 0.45),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Lifted off centre by a little, because the keyboard's
                    // half of the screen is where the composer is and a circle
                    // dead in the middle sits low against it.
                    const Spacer(flex: 3),
                    _Disc(
                      diameter: diameter,
                      progress: recorder.progress,
                      camera: ready ? camera : null,
                    ),
                    const SizedBox(height: 18),
                    _Pill(text: hint),
                    const Spacer(flex: 4),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The circle itself, with the minute drawn round it.
class _Disc extends StatelessWidget {
  const _Disc({
    required this.diameter,
    required this.progress,
    required this.camera,
  });

  final double diameter;
  final double progress;
  final CameraController? camera;

  @override
  Widget build(BuildContext context) {
    final live = camera;
    return SizedBox(
      width: diameter + 14,
      height: diameter + 14,
      child: CustomPaint(
        painter: _RingPainter(progress: progress),
        child: Center(
          child: Container(
            width: diameter,
            height: diameter,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // A soft halo, so the circle sits on the blurred chat rather
              // than being cut out of it.
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: 34,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: ClipOval(
              child: live == null
                  ? ColoredBox(
                      color: Colors.black.withValues(alpha: 0.8),
                      child: Center(
                        child: SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: AppColors.brandPrimary,
                          ),
                        ),
                      ),
                    )
                  : FittedBox(
                      // The camera hands back 4:3 and this is round: cover, so
                      // the circle is full of picture instead of letterbox.
                      fit: BoxFit.cover,
                      clipBehavior: Clip.hardEdge,
                      child: SizedBox(
                        width: live.value.previewSize?.height ?? 3,
                        height: live.value.previewSize?.width ?? 4,
                        child: CameraPreview(live),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.8),
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// The minute, drawn round the circle.
class _RingPainter extends CustomPainter {
  const _RingPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: size.width / 2 - 3,
    );
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white.withValues(alpha: 0.18),
    );
    if (progress <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * progress,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round
        ..color = AppColors.brandPrimary,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress;
}
