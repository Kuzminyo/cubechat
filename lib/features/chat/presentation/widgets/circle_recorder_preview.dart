import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../data/circle_recorder.dart';

/// What a circle looks like while it is being recorded.
///
/// The conversation goes behind glass and the circle takes the middle. A
/// circle is a camera pointed at your own face — you are looking at yourself,
/// not at the chat — so the chat stops competing for attention while it runs.
///
/// **The composer is not part of that.** It carries the seconds, the
/// slide-to-cancel and the send button: the controls of the thing being
/// blurred. Frosting them made the bar look disabled at the exact moment it is
/// the only part of the screen you can use. So the glass stops at the top of
/// the record button and the island below stands clear of it.
///
/// Shown through an [OverlayEntry] rather than in the composer's own column:
/// that column is what the conversation's bottom padding is measured off, and
/// a preview this size inside it would shove the whole chat upward while a
/// finger is held on the button that started it.
class CircleRecorderPreview extends StatelessWidget {
  const CircleRecorderPreview({
    super.key,
    required this.recorder,
    required this.glassHeight,
  });

  final CircleRecorder recorder;

  /// How tall the frosted region is, from the top of the screen.
  ///
  /// A height rather than a bottom inset, and that difference is the whole
  /// bug: the overlay lives in the root overlay's coordinate space — the
  /// window, system bars and all — while the screen height the composer knows
  /// about is the padded one. Subtracting one from the other left the glass
  /// reaching past the record button and over the island. Measured downward
  /// from a shared origin, there is nothing to get wrong.
  final double glassHeight;

  /// Light, not heavy. The conversation behind should still be recognisable as
  /// the chat you are in — the blur says "later", not "gone". Deliberately
  /// below [AppBlur.sigma]: this one runs over a live camera preview, which is
  /// the most expensive thing on the screen already.
  static const double backdropBlur = 9;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final diameter = math.min(media.size.width * 0.62, 270.0);
    return AnimatedBuilder(
      animation: recorder,
      builder: (context, _) {
        final camera = recorder.camera;
        final ready = recorder.isReady && camera != null;
        return Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: glassHeight,
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
            // The screen as a flash.
            //
            // A front camera has no light beside it on almost any phone, so
            // this is the light: a warm sheet over the blur and under the
            // circle, falling on the face rather than on the picture of it.
            // What every camera app does for a selfie in the dark.
            if (recorder.usesScreenLight)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: glassHeight,
                child: const IgnorePointer(
                  child: ColoredBox(color: Color(0xFFFFF1DA)),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: glassHeight,
              child: Column(
                children: [
                  const Spacer(),
                  // Pinch to zoom, let go and it goes back. Only the disc
                  // takes the gesture, so nothing is stolen from the finger
                  // still holding the record button below.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onScaleStart: (_) => recorder.beginZoom(),
                    onScaleUpdate: (d) => unawaited(recorder.zoomBy(d.scale)),
                    onScaleEnd: (_) => unawaited(recorder.resetZoom()),
                    child: _Disc(
                      diameter: diameter,
                      camera: ready ? camera : null,
                      progress: recorder.progress,
                    ),
                  ),
                  const Spacer(),
                  // Bottom left, above the timer. Beside the circle they sat
                  // where the eye is and the thumb is not — a control you have
                  // to reach across your own face to press.
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: _Controls(recorder: recorder),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The light and the lens, side by side under the circle.
class _Controls extends StatelessWidget {
  const _Controls({required this.recorder});

  final CircleRecorder recorder;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _RoundButton(
          icon: recorder.torchOn
              ? Icons.flashlight_on_rounded
              : Icons.flashlight_off_rounded,
          on: recorder.torchOn,
          onTap: () => unawaited(recorder.toggleTorch()),
        ),
        const SizedBox(width: 18),
        // Turning the phone round mid-circle.
        //
        // The camera plugin cannot hand a running capture to the other sensor,
        // so this stops the recording and starts a new one on the far lens.
        // The seconds reset in front of you, which is the honest way to show
        // that what was recorded is gone — the alternative was a button that
        // did nothing until the next circle, and it was asked for three times.
        _RoundButton(
          icon: Icons.flip_camera_ios_rounded,
          on: false,
          onTap: () => unawaited(recorder.flipLens()),
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.on,
    required this.onTap,
  });

  final IconData icon;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on
              ? const Color(0xFFFFF1DA)
              : Colors.black.withValues(alpha: 0.55),
          border: Border.all(
            color: Colors.white.withValues(alpha: on ? 0.9 : 0.28),
            width: 1.4,
          ),
        ),
        child: Icon(
          icon,
          size: 22,
          color: on ? const Color(0xFF17110A) : Colors.white,
        ),
      ),
    );
  }
}

/// The circle itself, with the minute drawn as an arc that grows round it.
class _Disc extends StatelessWidget {
  const _Disc({
    required this.diameter,
    required this.camera,
    required this.progress,
  });

  final double diameter;
  final CameraController? camera;
  final double progress;

  @override
  Widget build(BuildContext context) {
    // The arc, and only the arc. There is no track behind it — a full circle
    // of grey round the picture is the outline that was asked to go, and it
    // was drawing a second rim a hair outside the first. What is left is the
    // part that means something: how much of the minute has gone.
    return SizedBox(
      width: diameter + 16,
      height: diameter + 16,
      child: CustomPaint(
        painter: _ArcPainter(progress: progress),
        child: Center(child: _face()),
      ),
    );
  }

  Widget _face() {
    final live = camera;
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // A soft halo, so the circle sits on the blurred chat rather than
        // being cut out of it.
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
                // The camera hands back 4:3 and this is round: cover, so the
                // circle is full of picture instead of letterbox.
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: live.value.previewSize?.height ?? 3,
                  height: live.value.previewSize?.width ?? 4,
                  child: CameraPreview(live),
                ),
              ),
      ),
    );
  }
}

/// How much of the minute has gone, as a stroke that grows clockwise from the
/// top of the circle.
///
/// White rather than the brand colour: it sits on a live camera picture whose
/// colours are whatever the room is, and white is the one that reads on all of
/// them. Round-capped, because a growing line with a square end looks like it
/// has been cut off rather than like it is still going.
class _ArcPainter extends CustomPainter {
  const _ArcPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(
        center: Offset(size.width / 2, size.height / 2),
        radius: size.width / 2 - 3,
      ),
      -math.pi / 2,
      math.pi * 2 * progress.clamp(0.0, 1.0),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.progress != progress;
}
