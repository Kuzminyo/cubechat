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
            AppColors.bgTop.withValues(alpha: softBottom ? 0.30 : 0.88),
          ],
          stops: const [0, 0.62, 1],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(top: topInset),
        child: child,
      ),
    );
  }
}
