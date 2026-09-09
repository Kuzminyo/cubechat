import 'dart:async';
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
    required this.bottomClear,
  });

  final CircleRecorder recorder;

  /// How much of the bottom of the screen the glass must leave alone.
  ///
  /// The composer is down there, and while a circle records it is carrying the
  /// seconds, the slide-to-cancel and the send button — the controls of the
  /// thing being blurred. Frosting them made the bar look disabled at the
  /// exact moment it is the only part of the screen you can use.
  ///
  /// Measured off the record button rather than assumed, because the composer
  /// grows with a reply island, a draft and the keyboard.
  final double bottomClear;

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
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              bottom: bottomClear,
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
            // Almost no phone has a light beside the selfie lens, so the
            // hardware torch refuses and this takes over: a white sheet behind
            // the circle, which is what every camera app does for a
            // front-facing shot in the dark. It is over the blur and under the
            // circle, so it lights the face and not the picture of it.
            if (recorder.usesScreenLight)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                bottom: bottomClear,
                child: const IgnorePointer(
                  child: ColoredBox(color: Color(0xFFFFF4E2)),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              bottom: bottomClear,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Lifted off centre by a little, because the composer's
                  // half of the screen is the busy one and a circle dead in
                  // the middle sits low against it.
                  const Spacer(flex: 3),
                  // Pinch to zoom, let go and it goes back. Only the disc
                  // takes the gesture; the rest of the overlay stays
                  // transparent to touch so nothing is stolen from the finger
                  // still holding the record button below.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onScaleStart: (_) => recorder.beginZoom(),
                    onScaleUpdate: (d) => unawaited(recorder.zoomBy(d.scale)),
                    onScaleEnd: (_) => unawaited(recorder.resetZoom()),
                    child: _Disc(
                      diameter: diameter,
                      camera: ready ? camera : null,
                    ),
                  ),
                  const SizedBox(height: 20),
                  _TorchButton(recorder: recorder),
                  const Spacer(flex: 4),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The circle itself.
class _Disc extends StatelessWidget {
  const _Disc({required this.diameter, required this.camera});

  final double diameter;
  final CameraController? camera;

  @override
  Widget build(BuildContext context) {
    final live = camera;
    // No ring. It drew a second circle round the first and made the preview
    // look like a control rather than a picture; the seconds are on the
    // composer strip below, where the voice recorder puts them.
    return Center(
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
    );
  }
}

// The caption under the circle is gone. The composer strip below already says
// "slide left to cancel" while a finger is down, and a second sentence a
// hand's width above it was one instruction too many for a screen whose whole
// content is your own face.

/// The light, under the circle where a thumb can reach it.
///
/// Reachable with the *other* hand: the one holding the record button cannot
/// leave it without ending the recording, so this sits where a second thumb
/// lands rather than where a control usually goes.
class _TorchButton extends StatelessWidget {
  const _TorchButton({required this.recorder});

  final CircleRecorder recorder;

  @override
  Widget build(BuildContext context) {
    final on = recorder.torchOn;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(recorder.toggleTorch()),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on
              ? const Color(0xFFFFF4E2)
              : Colors.black.withValues(alpha: 0.5),
          border: Border.all(
            color: Colors.white.withValues(alpha: on ? 0.9 : 0.25),
            width: 1.4,
          ),
        ),
        child: Icon(
          on ? Icons.flashlight_on_rounded : Icons.flashlight_off_rounded,
          size: 22,
          color: on ? const Color(0xFF17110A) : Colors.white,
        ),
      ),
    );
  }
}

