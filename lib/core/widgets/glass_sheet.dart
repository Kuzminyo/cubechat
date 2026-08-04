import 'package:flutter/material.dart';

import 'floating_glass.dart';

/// How every bottom sheet in the app arrives and leaves.
///
/// Slower than Material's default and eased at both ends, because the default
/// is tuned for a slab that slides up from the edge of the screen and this is
/// an island that has to look like it floats there. The reverse is the half
/// people complained about: closing was instant, which reads as the sheet being
/// deleted rather than put away.
const AnimationStyle glassSheetMotion = AnimationStyle(
  duration: Duration(milliseconds: 340),
  reverseDuration: Duration(milliseconds: 280),
  curve: Curves.easeOutCubic,
  reverseCurve: Curves.easeInCubic,
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
/// caller's content sits inside one [FloatingGlass] island with air on all
/// sides, exactly like the bar it appears above.
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
        child: FloatingGlass(
          borderRadius: 28,
          padding: EdgeInsets.zero,
          child: builder(context),
        ),
      ),
    ),
  );
}
