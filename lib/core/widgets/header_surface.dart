import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// What a tab's header is drawn on.
///
/// A gradient in the palette's own colours rather than a flat fill or a pane of
/// glass: the screen behind it is an aurora, and a header that ignores the
/// palette reads as a strip cut out of a different app. It runs from the
/// palette's deepest tone at the top to its mid tone at the bottom edge, so
/// rows scrolling under it fade out rather than sliding under a lid.
///
/// Written for Chats and shared since Contacts and Nearby put their headers
/// over their lists too: with the list simply stopping under the subtitle,
/// every row was cut off by a hard line there ("the header is chopped").
class HeaderSurface extends StatelessWidget {
  const HeaderSurface({
    super.key,
    required this.child,
    this.topInset = 0,
    this.softBottom = false,
  });

  final double topInset;
  final Widget child;

  /// When true, the surface fades to nearly transparent at its bottom edge
  /// rather than ending at bgTop@0.88 — the soft landing for when nothing
  /// below it does the fade. Costs no height, so nothing under it moves; only
  /// the colour of the last few pixels changes.
  final bool softBottom;

  /// Where the surface reaches its mid tone, as a fraction of its height.
  static const double midStop = 0.62;

  /// How opaque the surface still is at the header's bottom edge, where
  /// whatever runs below it — Chats' folder row, the Contacts and Nearby veil —
  /// takes over and lets it go.
  static const double edgeAlpha = 0.88;

  /// The surface running out below a header: [from] down to nothing.
  ///
  /// Eased, not straight. A straight ramp to zero lands with a corner, and the
  /// eye reads a change of slope as a line — "the header has a border at the
  /// bottom", 2026-10-15, on a fade that was mathematically never a border.
  /// A smoothstep has no corner at either end.
  ///
  /// [start] and [end] place it inside a larger gradient, as fractions.
  static ({List<Color> colors, List<double> stops}) tail({
    double from = edgeAlpha,
    double start = 0,
    double end = 1,
  }) {
    const steps = 6;
    final colors = <Color>[];
    final stops = <double>[];
    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      final eased = t * t * (3 - 2 * t);
      colors.add(AppColors.bgTop.withValues(alpha: from * (1 - eased)));
      stops.add(start + (end - start) * t);
    }
    return (colors: colors, stops: stops);
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.bgDeep,
            AppColors.bgTop,
            AppColors.bgTop.withValues(alpha: softBottom ? 0.30 : edgeAlpha),
          ],
          stops: const [0, midStop, 1],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(top: topInset),
        child: child,
      ),
    );
  }
}
