import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../data/circle_recorder.dart';

/// What a circle looks like while it is being recorded.
///
/// Over the conversation rather than on a pushed route, because the finger
/// that started this is still on the composer button below and a route would
/// take the gesture with it. The same reason the voice strip lives inline.
class CircleRecorderPreview extends StatelessWidget {
  const CircleRecorderPreview({
    super.key,
    required this.recorder,
    required this.hint,
  });

  final CircleRecorder recorder;

  /// One line under the circle: how to send it, how to drop it.
  final String hint;

  /// How wide the circle is drawn. Big enough to see a face in, small enough
  /// that the conversation behind it is still there.
  static const double diameter = 232;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: recorder,
      builder: (context, _) {
        final camera = recorder.camera;
        final ready = recorder.isReady && camera != null;
        return IgnorePointer(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: diameter + 12,
                height: diameter + 12,
                child: CustomPaint(
                  painter: _RingPainter(progress: recorder.progress),
                  child: Center(
                    child: ClipOval(
                      child: SizedBox(
                        width: diameter,
                        height: diameter,
                        child: ready
                            ? FittedBox(
                                // The camera hands back 4:3 and the bubble is
                                // round: cover, so the circle is full of
                                // picture instead of full of letterbox.
                                fit: BoxFit.cover,
                                clipBehavior: Clip.hardEdge,
                                child: SizedBox(
                                  width: camera.value.previewSize?.height ?? 3,
                                  height: camera.value.previewSize?.width ?? 4,
                                  child: CameraPreview(camera),
                                ),
                              )
                            : ColoredBox(
                                color: Colors.black.withValues(alpha: 0.75),
                                child: Center(
                                  child: SizedBox(
                                    width: 30,
                                    height: 30,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 3,
                                      color: AppColors.brandPrimary,
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              // No clock here. The composer strip below already carries one,
              // in the place voice recording puts it, and two counts of the
              // same seconds a hand's width apart is one too many.
              const SizedBox(height: 10),
              _Pill(text: hint, strong: false),
            ],
          ),
        );
      },
    );
  }

}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.strong});

  final String text;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.white.withValues(alpha: strong ? 1 : 0.75),
          fontSize: strong ? 15 : 12,
          fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
          fontFeatures:
              strong ? const <FontFeature>[FontFeature.tabularFigures()] : null,
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
        ..color = Colors.white.withValues(alpha: 0.22),
    );
    if (progress <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * progress,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = AppColors.brandPrimary,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress;
}
