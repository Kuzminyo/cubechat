import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../data/circle_recorder.dart';

/// The screen while a circle is being recorded.
///
/// **It owns the whole screen, bar included.** The first two attempts cut the
/// glass off above the composer so the real one showed through, and both
/// looked wrong for the same reason: the cut-off is measured, the composer
/// moves with the keyboard, a reply island and a draft, and every mismatch is
/// a bright seam across the picture or a frosted control bar. So there is no
/// cut-off. The blur covers everything and this draws its own bar over the
/// top — the seconds, the way out, and the button — which is what Telegram
/// does and why theirs never has a seam in it.
///
/// The button under the finger is still the composer's while a finger is on
/// it: the pointer went down before this appeared, so the gesture belongs to
/// the recogniser down there and the one drawn here is a picture of it.
/// Once the recording is locked the finger is gone, and then the one here is
/// the real one — which is why it takes callbacks.
class CircleRecorderPreview extends StatelessWidget {
  const CircleRecorderPreview({
    super.key,
    required this.recorder,
    required this.locked,
    required this.hint,
    required this.cancelLabel,
    required this.onSend,
    required this.onCancel,
  });

  final CircleRecorder recorder;

  /// True once the press has ended and the recording carries on by itself.
  final bool locked;

  /// What a held finger can do: slide left to drop it.
  final String hint;

  /// What a lifted finger can do: press this to drop it.
  final String cancelLabel;

  final VoidCallback onSend;
  final VoidCallback onCancel;

  /// Light, not heavy. The conversation behind should still be recognisable as
  /// the chat you are in — the blur says "later", not "gone". Deliberately
  /// below [AppBlur.sigma]: this one runs over a live camera preview, which is
  /// the most expensive thing on the screen already.
  static const double backdropBlur = 10;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final diameter = math.min(media.size.width * 0.66, 300.0);
    // Above the keyboard when there is one, above the gesture bar when there
    // is not. The keyboard stays up while a circle records — it was being
    // dismissed, which shoved the whole chat about at the moment the screen is
    // supposed to hold still — so the bar has to clear it.
    final bottom = math.max(media.padding.bottom, media.viewInsets.bottom);
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          // **Outside every listener on purpose.**
          //
          // A full-screen gaussian over a live camera preview is the most
          // expensive thing this app ever draws, and it was inside a builder
          // that fires ten times a second with the recorder's clock. The
          // screen crawled and touches went missing with it — a saturated UI
          // thread drops taps as readily as frames. Nothing about the blur
          // changes while a circle records, so nothing about it rebuilds.
          Positioned.fill(
            child: IgnorePointer(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(
                  sigmaX: backdropBlur,
                  sigmaY: backdropBlur,
                ),
                child: ColoredBox(
                  color: AppColors.bgDeep.withValues(alpha: 0.55),
                ),
              ),
            ),
          ),
          // The screen as a flash. Over the blur and under the circle, so it
          // lights the face and not the picture of it. Its own listener, so
          // turning it on repaints a rectangle and not the gaussian.
          AnimatedBuilder(
            animation: recorder,
            builder: (context, _) => recorder.usesScreenLight
                ? const Positioned.fill(
                    child: IgnorePointer(
                      child: ColoredBox(color: Color(0xFFFFF1DA)),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: Column(
                children: [
                  const Spacer(flex: 4),
                  AnimatedBuilder(
                    animation: recorder,
                    builder: (context, _) {
                      final camera = recorder.camera;
                      final ready = recorder.isReady && camera != null;
                      return _Disc(
                        diameter: diameter,
                        camera: ready ? camera : null,
                        progress: recorder.progress,
                        front: recorder.isFront,
                      );
                    },
                  ),
                  const Spacer(flex: 5),
                ],
              ),
            ),
          ),
              // Pinch to zoom, let go and it goes back. A box the size of the
              // circle rather than the whole screen, so a stray touch near the
              // bar is not a zoom.
              Positioned.fill(
                child: Align(
                  alignment: const Alignment(0, -0.28),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onScaleStart: (_) => recorder.beginZoom(),
                    onScaleUpdate: (d) => unawaited(recorder.zoomBy(d.scale)),
                    onScaleEnd: (_) => unawaited(recorder.resetZoom()),
                    child: SizedBox(width: diameter, height: diameter),
                  ),
                ),
              ),
              // The light and the lens, left, above the bar.
              Positioned(
                left: 18,
                bottom: bottom + 96,
                // Its own listener too: the torch turning on is two circles
                // changing colour, not a reason to redraw the blur.
                child: AnimatedBuilder(
                  animation: recorder,
                  builder: (context, _) => _Controls(recorder: recorder),
                ),
              ),
              // Right above the button it is telling you to drag. Any higher
              // and it is an instruction floating in the picture rather than
              // one attached to the thing it is about.
              if (!locked)
                Positioned(
                  right: 20,
                  bottom: bottom + 74,
                  child: const _LockCapsule(),
                ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            // Its own listener, so the clock ticking repaints a bar and not a
            // full-screen gaussian.
            child: AnimatedBuilder(
              animation: recorder,
              builder: (context, _) => _Bar(
                bottomInset: bottom,
                // Read off the recorder rather than passed in from the screen:
                // an overlay entry does not rebuild with the widget that made
                // it, so a number handed over at insert time is the number it
                // would still be showing a minute later.
                elapsed: recorder.elapsed,
                locked: locked,
                hint: hint,
                cancelLabel: cancelLabel,
                onSend: onSend,
                onCancel: onCancel,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The seconds, the way out, and the button.
///
/// Drawn here rather than left to the composer underneath, because the
/// composer's position is a moving target and a frosted copy of it read as
/// disabled at the moment it is the only usable thing on screen.
class _Bar extends StatelessWidget {
  const _Bar({
    required this.bottomInset,
    required this.elapsed,
    required this.locked,
    required this.hint,
    required this.cancelLabel,
    required this.onSend,
    required this.onCancel,
  });

  final double bottomInset;
  final Duration elapsed;
  final bool locked;
  final String hint;
  final String cancelLabel;
  final VoidCallback onSend;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 0, 14, bottomInset + 12),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 54,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(27),
              ),
              child: Row(
                children: [
                  // The dot that says it is running, and the count beside it.
                  Container(
                    width: 9,
                    height: 9,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.danger,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _clock(elapsed),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      // Tabular, so the bar does not twitch every tenth of a
                      // second as the digits change width.
                      fontFeatures: <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                  // The hint while a finger is down, and the word to press
                  // whether it is or not. Flexible rather than Expanded and
                  // allowed to disappear: on a narrow phone the sentence was
                  // squeezing the word next to it into "СКАСУВА…", and of the
                  // two the one you can press matters more than the one that
                  // describes a gesture.
                  if (!locked)
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Text(
                          hint,
                          maxLines: 1,
                          overflow: TextOverflow.fade,
                          softWrap: false,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.65),
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  // Always pressable, locked or not. It was only there once
                  // the recording had been locked, on the reasoning that a
                  // held finger cancels by sliding — and then a gesture broke
                  // somewhere and the only way out of a running circle was the
                  // system back button, which leaves the chat. A way out that
                  // depends on the gesture working is not a way out.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onCancel,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 12,
                      ),
                      child: Text(
                        cancelLabel.toUpperCase(),
                        style: const TextStyle(
                          color: AppColors.danger,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Pressable whether the finger is still down or not.
          //
          // It was pressable only once locked, on the reasoning that letting
          // go is what sends — and then letting go stopped working and there
          // was no second way to finish a circle. Same lesson as the cancel
          // beside it: a control that depends on a gesture behaving is not a
          // control.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onSend,
            child: Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.brandPrimary,
              ),
              child: Icon(
                locked ? Icons.send_rounded : Icons.videocam_rounded,
                size: 24,
                color: AppColors.bgDeep,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _clock(Duration d) {
    final s = d.inSeconds;
    final tenths = (d.inMilliseconds ~/ 100) % 10;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')},$tenths';
  }
}

/// Drag up to lock, drawn where the thumb is rather than where there is room.
class _LockCapsule extends StatelessWidget {
  const _LockCapsule();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: 42,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(21),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.22),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.keyboard_double_arrow_up_rounded,
              size: 20,
              color: Colors.white.withValues(alpha: 0.85),
            ),
            const SizedBox(height: 3),
            Icon(
              Icons.lock_open_rounded,
              size: 15,
              color: Colors.white.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }
}

/// The light and the lens, side by side.
class _Controls extends StatelessWidget {
  const _Controls({required this.recorder});

  final CircleRecorder recorder;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RoundButton(
          icon: recorder.torchOn
              ? Icons.flashlight_on_rounded
              : Icons.flashlight_off_rounded,
          on: recorder.torchOn,
          onTap: () => unawaited(recorder.toggleTorch()),
        ),
        const SizedBox(width: 14),
        // Turning the phone round mid-circle.
        //
        // The camera plugin cannot hand a running capture to the other sensor,
        // so this stops the recording and starts a new one on the far lens.
        // The seconds reset in front of you, which is the honest way to show
        // that what was recorded is gone.
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
    required this.front,
  });

  final double diameter;
  final CameraController? camera;
  final double progress;

  /// Which way the lens points. Only used to turn the picture over when it
  /// changes — the same coin flip the composer button does between the
  /// microphone and the camera, because it is the same act: this side, that
  /// side.
  final bool front;

  @override
  Widget build(BuildContext context) {
    // The arc, and only the arc. There is no track behind it — a full circle
    // of grey round the picture is the outline that was asked to go.
    return SizedBox(
      width: diameter + 16,
      height: diameter + 16,
      child: CustomPaint(
        painter: _ArcPainter(progress: progress),
        child: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: front ? 0 : 1),
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeInOutCubic,
            builder: (context, t, child) => Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.0012)
                ..rotateY(t * math.pi),
              // Past halfway the picture is arriving back to front, so it is
              // mirrored back. Without this the far side of the coin shows a
              // reversed camera.
              child: Transform(
                alignment: Alignment.center,
                transform: t > 0.5
                    ? (Matrix4.identity()..rotateY(math.pi))
                    : Matrix4.identity(),
                child: child,
              ),
            ),
            child: _face(),
          ),
        ),
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
                // Cover, so the circle is full of picture instead of
                // letterbox. Scaling by width, which keeps the whole of what
                // the lens sees left to right and crops top and bottom — the
                // only way a round window can be cut out of a rectangle.
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
