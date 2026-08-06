import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// The nav bar's pane of glass, on its own so anything else that has to look
/// like the bar can *be* the bar rather than an approximation of it.
///
/// The recipe matters in every part, and each part is there to stop the surface
/// reading as a panel:
///
///  * **Two tight black shadows**, no brand tint. A coloured glow paints a halo
///    on the screen around the capsule, and a wide soft shadow smears a dark
///    band under it — both of which are the "plate" this surface must not sit
///    on.
///  * **A real backdrop blur**, because unlike the aurora (four soft radial
///    gradients, which blur to themselves) what is behind this is a list, a
///    conversation, a photo grid — detail worth softening, and the thing that
///    makes it read as glass rather than as tint.
///  * **A dark gradient in the palette's own colours**: a whisper of the
///    palette's white at the top falling to the palette's near-black. It used
///    to fall to literal black on the theory that the pane should contribute no
///    colour of its own — which works on the green theme, where black over a
///    green aurora goes green, and nowhere else. On rose the bar was a black
///    slab across the bottom of a pink screen. See [AppColors.pane].
///  * **A hairline border**, which is what separates "a pane of glass" from "a
///    darker area of the background".
class BarGlass extends StatelessWidget {
  const BarGlass({
    super.key,
    required this.child,
    this.radius = 999,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
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
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter.grouped(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColors.glass(0.07),
                  AppColors.pane(0.52),
                  AppColors.pane(0.66),
                ],
                stops: const [0, 0.35, 1],
              ),
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: AppColors.glass(0.16)),
            ),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}
