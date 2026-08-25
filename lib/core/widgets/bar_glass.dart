import 'package:flutter/material.dart';

import '../theme/colors.dart';
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
              // Solid, and therefore not blurred at all.
              //
              // This surface used to be a translucent pane over a live
              // backdrop filter, and the filter was dropped while anything
              // moved — a scroll, and since the transition work, a route
              // sliding too. That is invisible on a pane you look *through*
              // only when what is behind it is already moving, and the bar
              // sits still while the app moves under it, so the switch read as
              // the bar itself changing: solid, then see-through, then solid.
              //
              // An opaque fill answers that and costs nothing to draw. There
              // is no blur to lose because there is nothing showing through to
              // blur, which also takes a full-screen-width gaussian out of
              // every frame the bar is on screen — the cheapest version of a
              // change asked for on looks alone.
              //
              // The gradient stays: it is what keeps the bar from reading as a
              // flat slab, and top-to-bottom shading is most of what made the
              // translucent version look like glass in the first place.
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      AppColors.pane(0.97),
                      AppColors.pane(0.99),
                      AppColors.paneBase,
                    ],
                    stops: const [0, 0.35, 1],
                  ),
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(color: AppColors.glass(0.16)),
                ),
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
