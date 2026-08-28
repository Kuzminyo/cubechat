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
        // A shadow of its own, unlike the floating panes.
        //
        // Those sit over a wallpaper and a photograph, where a black halo does
        // not read as height — it reads as grime, which is why their list is
        // empty and why this file used to share it. The bar is different in
        // every way that matters: it is opaque, it never moves, and what is
        // behind it is the app's own backdrop rather than somebody's holiday
        // photo. Without a shadow it reads as painted onto the screen instead
        // of lying on it, which is what "flat, 2D" means.
        //
        // Two of them, both tight and both pulled in with negative spread: a
        // close contact shadow that says the bar is a millimetre off the
        // surface, and a wider ambient one that gives it somewhere to be. A
        // single wide soft shadow would smear a dark band under the bar, and
        // that band is the "plate" this surface exists not to sit on.
        boxShadow: const [
          BoxShadow(
            color: Color(0x73000000),
            blurRadius: 12,
            offset: Offset(0, 5),
            spreadRadius: -5,
          ),
          BoxShadow(
            color: Color(0x40000000),
            blurRadius: 26,
            offset: Offset(0, 12),
            spreadRadius: -14,
          ),
        ],
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
                  // A lit top edge, then a long fall to the darkest tone.
                  //
                  // The old ramp went from 97% to 100% opacity of the same
                  // colour, which is a change nobody can see: the bar was one
                  // flat tone with a hairline round it. What makes a surface
                  // look like an object is a light source, and the app has one
                  // by convention — above. So the first two percent of the
                  // height carry the palette's white, the body sits in the
                  // pane's own dark, and the bottom is darker still, as if the
                  // far edge were turning away.
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      AppColors.glass(0.16),
                      AppColors.pane(0.94),
                      AppColors.paneBase,
                      AppColors.pane(0.99),
                    ],
                    stops: const [0, 0.06, 0.72, 1],
                  ),
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(color: AppColors.glass(0.14)),
                ),
              ),
            ),
            // The rim light.
            //
            // A border is the same brightness the whole way round, which reads
            // as a drawn outline. Something lit from above catches the light on
            // its upper edge and nowhere else, and that single asymmetry is
            // most of what tells the eye a surface has a thickness. Flutter has
            // no gradient border, so it is a hairline of its own laid along the
            // top inside the clip — where the rounded corners cut it off
            // exactly where the curve turns away from the light.
            Positioned(
              left: radius / 2,
              right: radius / 2,
              top: 0,
              height: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      AppColors.glass(0),
                      AppColors.glass(0.34),
                      AppColors.glass(0),
                    ],
                  ),
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
