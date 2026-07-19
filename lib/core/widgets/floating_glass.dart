import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// A single levitating pane of smoked glass — the same treatment the floating
/// nav bar uses, offered as a reusable surface so a list of them reads as a
/// row of separate islands over the aurora rather than cards on a plate.
///
/// The recipe is deliberately the nav bar's, not [GlassCard]'s bright frost:
///
///  * a **neutral dark** gradient (a whisper of white at the top, deep black
///    below) so the blurred aurora shows through but the pane contributes no
///    colour of its own — it reads as smoked glass, not a green tile;
///  * a **crisp hairline** border, which is what separates "a pane of glass"
///    from "a darker patch of the background";
///  * **two tight black shadows** — a close contact shadow and a slightly
///    wider ambient one, both pulled in with negative spread. A wide, soft
///    drop shadow would smear a dark band under the row, and that band is
///    exactly the "plate" these islands must not sit on.
///
/// Each pane carries its own [BackdropFilter]; a [RepaintBoundary] keeps that
/// blur's repaints from dirtying its neighbours as the list scrolls.
class FloatingGlass extends StatelessWidget {
  const FloatingGlass({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.borderRadius = 18,
    this.onTap,
    this.onLongPressAt,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final VoidCallback? onTap;

  /// Long-press reporting the global press point, so a caller can anchor a
  /// popup to the finger. InkWell.onLongPress gives no position, so this rides
  /// an outer detector that only claims the long-press — tap (and its ripple)
  /// still belong to the InkWell.
  final void Function(Offset globalPosition)? onLongPressAt;

  /// The pair of shadows that makes a pane hover: a close contact shadow and a
  /// slightly wider ambient one, both pulled in with negative spread.
  ///
  /// Exposed because not every island can be a [FloatingGlass]. A chat bubble
  /// has to keep its own sender colour, so it builds its own surface — but it
  /// must levitate *identically*, and two hand-tuned shadow lists would drift
  /// apart the first time either is touched.
  static List<BoxShadow> get shadows => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.50),
          blurRadius: 10,
          offset: const Offset(0, 4),
          spreadRadius: -4,
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.30),
          blurRadius: 20,
          offset: const Offset(0, 8),
          spreadRadius: -14,
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius);

    Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: shadows,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: 0.07),
                  Colors.black.withValues(alpha: 0.52),
                  Colors.black.withValues(alpha: 0.66),
                ],
                stops: const [0, 0.35, 1],
              ),
              borderRadius: radius,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.16),
              ),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: radius,
                hoverColor: AppColors.glassHover,
                child: Padding(padding: padding, child: child),
              ),
            ),
          ),
        ),
      ),
    );

    if (onLongPressAt != null) {
      surface = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPressStart: (d) => onLongPressAt!(d.globalPosition),
        child: surface,
      );
    }

    return RepaintBoundary(child: surface);
  }
}
