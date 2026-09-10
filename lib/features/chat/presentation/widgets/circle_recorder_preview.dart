import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../../../../core/util/motion.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/theme/glass.dart';
import '../../../../core/widgets/circle_video_icon.dart';
import '../../../../core/widgets/glass_toast.dart';
import '../../../../l10n/app_localizations.dart';
import '../../data/circle_recorder.dart';

/// A full-screen recording surface. Its hit-test bounds must fill the overlay:
/// a Stack with only positioned children and a shrinking light listener could
/// paint controls outside its own bounds, where taps could never reach them.
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
  final bool locked;
  final String hint;
  final String cancelLabel;
  final VoidCallback onSend;
  final VoidCallback onCancel;

  // Keep the existing full-screen blur budget; panel glass uses AppBlur.pane.
  static const double backdropBlur = 10;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final t = AppLocalizations.of(context);
    return TextFieldTapRegion(
      child: Focus(
        canRequestFocus: false,
        descendantsAreFocusable: false,
        // **Nothing wraps the whole overlay in an Opacity any more.**
        //
        // It used to, and that is one widget doing two unhelpful things at
        // once. An `Opacity` below 1 forces everything under it into an
        // offscreen texture, and what was under it here is a full-screen
        // `BackdropFilter` — so every frame of the entrance rendered the blur
        // into a buffer and then composited the buffer, which is the most
        // expensive way to fade the most expensive thing on the screen. On top
        // of that it faded the disc and the blur together, so the picture
        // arrived as a wash rather than as something opening.
        //
        // The parts move separately now: the dim behind the blur lerps its
        // alpha, which is a colour and costs nothing, and the disc scales up
        // from nine tenths inside its own small layer. The blur itself is not
        // animated at all — a blur whose sigma changes is re-rendered every
        // frame, and nobody has ever noticed it arriving.
        //
        // The subtree rebuilds each frame of the entrance instead of being
        // cached behind `child:`, and that is the cheaper half of the trade: a
        // build here measured about a millisecond, against re-rendering a
        // full-screen gaussian into a texture sixty times a second.
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: AppMotion.duration(context, AppMotion.entrance),
          curve: Curves.easeOutCubic,
          builder: (context, entrance, _) => SizedBox.expand(
            child: Material(
              type: MaterialType.transparency,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final bottom =
                      math.max(media.padding.bottom, media.viewInsets.bottom);
                  final top = media.padding.top + 20;
                  final available = math.max(
                    0.0,
                    constraints.maxHeight - bottom - top - 200,
                  );
                  final keyboardOpen = media.viewInsets.bottom > 0;
                  final diameter = math.min(
                    math.min(
                      constraints.maxWidth * (keyboardOpen ? .58 : .78),
                      keyboardOpen ? 240.0 : 320.0,
                    ),
                    math.max(72.0, available - 16),
                  );
                  final discTop =
                      top + math.max(0.0, (available - diameter - 16) / 2);
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      // Block fresh touches from reaching the hidden composer. The
                      // original held pointer retains its existing gesture recognizer.
                      const ModalBarrier(
                        dismissible: false,
                        color: Colors.transparent,
                      ),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: BackdropFilter(
                            filter: ui.ImageFilter.blur(
                              sigmaX: backdropBlur,
                              sigmaY: backdropBlur,
                            ),
                            // The dim carries the fade. Changing a colour's
                            // alpha is a paint parameter, not a layer.
                            child: ColoredBox(
                              color: AppColors.bgDeep
                                  .withValues(alpha: .38 * entrance),
                            ),
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedBuilder(
                            animation: recorder,
                            builder: (context, _) => ColoredBox(
                              color: recorder.usesScreenLight
                                  ? const Color(0xFFFFF1DA)
                                  : Colors.transparent,
                            ),
                          ),
                        ),
                      ),
                      AnimatedPositioned(
                        duration: AppMotion.duration(context, AppMotion.expand),
                        curve: Curves.easeOutCubic,
                        top: discTop,
                        left: (constraints.maxWidth - diameter - 16) / 2,
                        width: diameter + 16,
                        height: diameter + 16,
                        child: GestureDetector(
                          key: const ValueKey('circle-camera-preview'),
                          onScaleStart: (_) => recorder.beginZoom(),
                          onScaleUpdate: (details) {
                            if (details.pointerCount > 1) {
                              unawaited(recorder.zoomBy(details.scale));
                            }
                          },
                          onScaleEnd: (_) => unawaited(recorder.resetZoom()),
                          // The disc is what opens. Nine tenths to full, on the
                          // same curve the dim behind it is using, so the
                          // picture grows into place instead of appearing at
                          // full size and merely getting brighter. Scale on a
                          // circle costs one transform and no layer at all.
                          child: Transform.scale(
                            scale: 0.9 + 0.1 * entrance,
                            child: Opacity(
                              // Small, round, and the only opacity left. It is
                              // the disc's own layer rather than the whole
                              // screen's, which is the difference this change
                              // is about.
                              opacity: entrance,
                              child: AnimatedBuilder(
                                animation: recorder,
                                builder: (context, _) => _Disc(
                                  diameter: diameter,
                                  changing: recorder.isFlipping,
                                  camera:
                                      recorder.isReady ? recorder.camera : null,
                                  progress: recorder.progress,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      AnimatedPositioned(
                        duration: AppMotion.duration(context, AppMotion.expand),
                        curve: Curves.easeOutCubic,
                        top: discTop + diameter + 28,
                        left: 24,
                        right: 24,
                        child: IgnorePointer(
                          child: Text(
                            locked ? t.circleHintLocked : hint,
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.ink(.7),
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      AnimatedPositioned(
                        duration: AppMotion.duration(context, AppMotion.expand),
                        curve: Curves.easeOutCubic,
                        left: 18,
                        right: 18,
                        bottom: bottom + 84,
                        child: Row(
                          children: [
                            AnimatedBuilder(
                              animation: recorder,
                              builder: (context, _) => Row(
                                children: [
                                  _GlassButton(
                                    key: const ValueKey('circle-light'),
                                    label: t.circleLight,
                                    icon: Icon(
                                      recorder.torchOn
                                          ? Icons.flashlight_on_rounded
                                          : Icons.flashlight_off_rounded,
                                    ),
                                    selected: recorder.torchOn,
                                    onTap: recorder.isFinishing ||
                                            recorder.isFlipping
                                        ? null
                                        : () =>
                                            unawaited(recorder.toggleTorch()),
                                  ),
                                  const SizedBox(width: 12),
                                  _GlassButton(
                                    key: const ValueKey('circle-flip'),
                                    label: t.circleSwitchCamera,
                                    // The same icon throughout. It used to
                                    // become a spinner for the fraction of a
                                    // second the sensor takes, which reads as
                                    // something going wrong rather than as
                                    // something happening: the recording never
                                    // stopped, the picture just changed. The
                                    // button is still refused while the swap is
                                    // in flight, which is what actually needed
                                    // saying.
                                    icon: const Icon(
                                      Icons.flip_camera_ios_rounded,
                                    ),
                                    onTap: recorder.isFinishing ||
                                            recorder.isFlipping
                                        ? null
                                        : () async {
                                            await recorder.flipLens();
                                            if (context.mounted &&
                                                recorder.error != null) {
                                              showGlassToast(
                                                context,
                                                t.circleCameraSwitchFailed,
                                                tone: ToastTone.danger,
                                              );
                                            }
                                          },
                                  ),
                                ],
                              ),
                            ),
                            const Spacer(),
                            if (!locked)
                              IgnorePointer(
                                child: _GlassPanel(
                                  radius: 24,
                                  child: SizedBox(
                                    width: 48,
                                    height: 64,
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.keyboard_arrow_up_rounded,
                                          color: AppColors.textOnGlass,
                                        ),
                                        Icon(
                                          Icons.lock_open_rounded,
                                          size: 18,
                                          color: AppColors.textOnGlass,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      AnimatedPositioned(
                        duration: AppMotion.duration(context, AppMotion.expand),
                        curve: Curves.easeOutCubic,
                        left: 14,
                        right: 14,
                        bottom: bottom + 12,
                        child: AnimatedBuilder(
                          animation: recorder,
                          builder: (context, _) => Row(
                            children: [
                              Expanded(
                                child: _GlassPanel(
                                  radius: 28,
                                  child: SizedBox(
                                    height: 56,
                                    child: Padding(
                                      padding: const EdgeInsets.only(
                                        left: 16,
                                        right: 4,
                                      ),
                                      child: Row(
                                        children: [
                                          const SizedBox.square(
                                            dimension: 8,
                                            child: DecoratedBox(
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: AppColors.danger,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 9),
                                          Text(
                                            _clock(recorder.elapsed),
                                            style: TextStyle(
                                              color: AppColors.textOnGlass,
                                              fontSize: 15,
                                              fontWeight: FontWeight.w600,
                                              fontFeatures: const [
                                                FontFeature.tabularFigures(),
                                              ],
                                            ),
                                          ),
                                          Expanded(
                                            child: TextButton(
                                              key: const ValueKey(
                                                'circle-cancel',
                                              ),
                                              onPressed: recorder.isFinishing
                                                  ? null
                                                  : onCancel,
                                              style: TextButton.styleFrom(
                                                foregroundColor:
                                                    AppColors.danger,
                                                minimumSize: const Size(48, 48),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 8,
                                                ),
                                              ),
                                              child: FittedBox(
                                                fit: BoxFit.scaleDown,
                                                child: Text(
                                                  cancelLabel.toUpperCase(),
                                                  maxLines: 1,
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Semantics(
                                label: t.chatSend,
                                button: true,
                                child: GestureDetector(
                                  key: const ValueKey('circle-send'),
                                  behavior: HitTestBehavior.opaque,
                                  onTap: recorder.isFinishing ? null : onSend,
                                  child: Container(
                                    width: 56,
                                    height: 56,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: AppColors.brandPrimary,
                                    ),
                                    child: Center(
                                      child: recorder.isFinishing
                                          ? SizedBox.square(
                                              dimension: 20,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: AppColors.bgDeep,
                                              ),
                                            )
                                          : IconTheme(
                                              data: IconThemeData(
                                                color: AppColors.bgDeep,
                                                size: 24,
                                              ),
                                              child: locked
                                                  ? const Icon(
                                                      Icons.send_rounded,
                                                    )
                                                  : const CircleVideoIcon(),
                                            ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _clock(Duration value) =>
      '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';
}

/// Actual clipped backdrop glass, below all labels and touch targets.
class _GlassPanel extends StatelessWidget {
  const _GlassPanel({required this.child, this.radius = 24});
  final Widget child;
  final double radius;
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: GlassBlur(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.pane(.34),
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: AppColors.glass(.18)),
            ),
            child: child,
          ),
        ),
      );
}

class _GlassButton extends StatelessWidget {
  const _GlassButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.selected = false,
  });
  final String label;
  final Widget icon;
  final VoidCallback? onTap;
  final bool selected;
  @override
  Widget build(BuildContext context) => _GlassPanel(
        child: IconButton(
          tooltip: label,
          onPressed: onTap,
          style: IconButton.styleFrom(
            minimumSize: const Size(48, 48),
            foregroundColor:
                selected ? AppColors.brandPrimary : AppColors.textOnGlass,
          ),
          icon: icon,
        ),
      );
}

class _Disc extends StatefulWidget {
  const _Disc({
    required this.diameter,
    required this.camera,
    required this.progress,
    required this.changing,
  });
  final bool changing;
  final double diameter;
  final CameraController? camera;
  final double progress;
  @override
  State<_Disc> createState() => _DiscState();
}

class _DiscState extends State<_Disc> with SingleTickerProviderStateMixin {
  late final AnimationController _flip = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    reverseDuration: const Duration(milliseconds: 300),
  );
  @override
  void didUpdateWidget(_Disc oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.changing == oldWidget.changing) return;
    if (AppMotion.reduced(context)) {
      _flip.value = widget.changing ? 1 : 0;
      return;
    }
    if (widget.changing) {
      _flip.forward();
    } else {
      _flip.reverse();
    }
  }

  @override
  void dispose() {
    _flip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _flip,
        child: _picture(),
        builder: (context, child) {
          final turn = Curves.easeInOutCubic.transform(_flip.value);
          // Turn edge-on while the native sensor is being rebound. Never expose
          // the back of the texture: saved/front mirroring belongs to the camera.
          return Transform(
            key: const ValueKey('circle-flip-transform'),
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, .0015)
              ..rotateY(AppMotion.reduced(context) ? 0 : turn * math.pi / 2),
            child: Opacity(opacity: 1 - turn, child: child),
          );
        },
      );

  Widget _picture() => CustomPaint(
        painter: _ArcPainter(progress: widget.progress),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: ClipOval(
            child: SizedBox.square(
              dimension: widget.diameter,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: AppColors.bgDeep),
                  if (widget.camera != null)
                    FittedBox(
                      fit: BoxFit.cover,
                      clipBehavior: Clip.hardEdge,
                      child: SizedBox(
                        width: widget.camera!.value.previewSize?.height ?? 3,
                        height: widget.camera!.value.previewSize?.width ?? 4,
                        child: RepaintBoundary(
                          child: CameraPreview(widget.camera!),
                        ),
                      ),
                    ),
                  // Only while there is no picture at all. A sensor swap keeps
                  // the last frame on screen and replaces it when the other
                  // lens is ready, which is what a flip looks like everywhere
                  // else; putting a spinner over the face mid-sentence was the
                  // thing that made it feel broken.
                  if (widget.camera == null)
                    Center(
                      child: SizedBox.square(
                        dimension: 28,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.brandPrimary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
}

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
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = AppColors.textOnGlass,
    );
  }

  @override
  bool shouldRepaint(_ArcPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
