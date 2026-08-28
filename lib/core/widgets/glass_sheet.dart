import 'package:flutter/material.dart';

import 'bar_glass.dart';

/// How every bottom sheet in the app arrives and leaves.
///
/// Slower than Material's default and eased at both ends, because the default
/// is tuned for a slab that slides up from the edge of the screen and this is
/// an island that has to look like it floats there. The reverse is the half
/// people complained about: closing was instant, which reads as the sheet being
/// deleted rather than put away.
/// How a sheet arrives and leaves.
///
/// Leaving was 280 ms on `easeInCubic`, which is the textbook exit curve and is
/// wrong for this particular sheet. `easeIn` starts slowly and *accelerates*,
/// so the last third of the travel happens in almost no time — on a small
/// element that reads as decisiveness, and on the media island, which is nearly
/// the whole screen, it reads as the thing being snatched away. Reported as
/// having no closing animation at all, which is what "too fast to see" means.
///
/// Symmetric now, and at the same 340 ms as the arrival. `easeInOutCubic`
/// eases away from rest and eases back into it, so the island is still moving
/// visibly when it reaches the bottom of the screen instead of disappearing off
/// the last few hundred pixels in two frames.
const AnimationStyle glassSheetMotion = AnimationStyle(
  duration: Duration(milliseconds: 340),
  reverseDuration: Duration(milliseconds: 340),
  curve: Curves.easeOutCubic,
  reverseCurve: Curves.easeInOutCubic,
);

/// A modal sheet that floats, the way the nav bar and the composer do.
///
/// Material's sheet is a plate welded to the bottom edge: an opaque fill, full
/// width, square corners where it meets the screen. Everything else in this app
/// is a pane of smoked glass with the aurora running behind and past it, and a
/// sheet that reintroduced the plate was the one surface that looked borrowed
/// from another application.
///
/// So: no background of its own, no scrim of fill behind the content — the
/// caller's content sits inside one [BarGlass] island with air on all sides,
/// which is not merely *like* the nav bar's surface, it is the same widget.
Future<T?> showGlassSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool useRootNavigator = false,
  bool isScrollControlled = true,
  EdgeInsets margin = const EdgeInsets.fromLTRB(10, 0, 10, 10),
}) {
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    isScrollControlled: isScrollControlled,
    // The three that stop Material from painting a plate.
    backgroundColor: Colors.transparent,
    elevation: 0,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    sheetAnimationStyle: glassSheetMotion,
    builder: (context) => SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: margin.left,
          right: margin.right,
          // Above the keyboard when there is one, above the gesture bar when
          // there is not.
          bottom: margin.bottom + MediaQuery.viewInsetsOf(context).bottom,
        ),
        // The bar's own glass, not an approximation of it: same blur, same
        // neutral gradient, same hairline, same two black shadows. A sheet that
        // mixed its own recipe was the surface that still looked filled.
        //
        // Capped below the status bar. `isScrollControlled` lets a sheet grow
        // to the full height, and a sheet with a text field grows exactly that
        // far when the keyboard opens — the title then slid under the clock.
        // The cap leaves the top inset plus a little air clear; a short sheet
        // is unaffected because it never reaches the ceiling.
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height -
                MediaQuery.paddingOf(context).top -
                12,
          ),
          child: BarGlass(
            radius: 28,
            child: builder(context),
          ),
        ),
      ),
    ),
  );
}
