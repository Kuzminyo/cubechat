import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/glass.dart';
import '../util/ui_activity.dart';
import 'floating_glass.dart';

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
        // Shared, not a second hand-tuned copy — which is what this was, and
        // it is why the pair outlived the comment in FloatingGlass telling
        // anyone editing them to keep the two in step.
        boxShadow: FloatingGlass.shadows,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        // The surface sits *beside* the content in a stack rather than around
        // it, because the blur comes and goes with scrolling and the content
        // must not come and go with it.
        //
        // It used to wrap: the builder returned either `BackdropFilter(child:
        // pane)` or `pane`, so the widget at that position in the tree changed
        // type mid-gesture, and Flutter tore down the whole subtree under it
        // and built a fresh one. Everything the caller had put inside was
        // remounted — which is why the photo grid in the picker sheet snapped
        // back to the top and reloaded the instant a drag started, i.e. would
        // not scroll at all. Nothing above the content changes shape now.
        child: Stack(
          children: [
            Positioned.fill(
              child: ValueListenableBuilder<bool>(
                valueListenable: UiActivity.instance.isScrolling,
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
                ),
                builder: (context, scrolling, pane) {
                  // A live backdrop filter has to resample the moving list
                  // every frame. The pane's own tint stays visually identical
                  // during the gesture; the expensive blur returns when motion
                  // stops.
                  if (scrolling) return pane!;
                  return BackdropFilter(filter: AppBlur.pane, child: pane!);
                },
              ),
            ),
            // The one unpositioned child, so it is what the stack sizes itself
            // to — exactly as when it was the decorated box's child.
            Padding(padding: padding, child: child),
          ],
        ),
      ),
    );
  }
}
