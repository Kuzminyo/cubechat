import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import 'triple_tap_detector.dart';

/// The top of a main tab: a mark, the tab's name, a line under it, and up to
/// a couple of buttons on the right.
///
/// One widget for Chats, Contacts and Nearby because they used to be three,
/// each with its own margin, mark size and title height — so changing tab
/// shifted the title a few points sideways and about ten up or down, and the
/// screen read as jumping. Every number that places something is a constant
/// here, and the title row has one height whether or not there are buttons in
/// it, so nothing moves when a tab has fewer of them.
class TabHeader extends StatelessWidget {
  const TabHeader({
    super.key,
    required this.mark,
    required this.title,
    this.subtitle,
    this.subtitleTrailing,
    this.actions = const [],
    this.titleKey,
    this.subtitleKey,
    this.onTitleTripleTap,
    this.bottomPadding = 0,
  });

  static const double sidePadding = 20;
  static const double topPadding = 12;

  /// The square the mark is drawn in; a mark smaller than this is centred in
  /// it, so a 30-point icon and a 32-point logo start their titles together.
  static const double markBox = 32;
  static const double markGap = 12;

  /// The title row's height: a header button's touch target, so a row with
  /// buttons and a row without are the same height.
  static const double rowHeight = 44;
  static const double subtitleSize = 13;

  /// The subtitle line's height, fixed: tall enough for a pill beside it (the
  /// scanning pulse on Nearby), so a page that shows the pill and one that
  /// does not leave the header — and everything under it — at one height.
  /// Measured: the pill made the header 11 points taller on one page only.
  static const double subtitleRowHeight = 28;

  /// The whole header with a subtitle, which every tab has.
  static const double height = topPadding + rowHeight + subtitleRowHeight;

  /// On the mark's box, so a test can find where it landed.
  static const markKey = ValueKey('tab-header-mark');

  final Widget mark;
  final String title;
  final String? subtitle;

  /// Beside the subtitle, at its end — the scanning pulse on Nearby.
  final Widget? subtitleTrailing;

  /// [HeaderIconButton]s, [MoreButton]s, or a slot of the same height.
  final List<Widget> actions;

  final Key? titleKey;
  final Key? subtitleKey;

  /// The Chats title's emergency wipe gesture.
  final VoidCallback? onTitleTripleTap;

  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    Widget titleText = Text(
      title,
      key: titleKey,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppTypography.display(),
    );
    final tripleTap = onTitleTripleTap;
    if (tripleTap != null) {
      titleText = TripleTapDetector(onTripleTap: tripleTap, child: titleText);
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(
        sidePadding,
        topPadding,
        sidePadding,
        bottomPadding,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: rowHeight,
            child: Row(
              children: [
                SizedBox.square(
                  key: markKey,
                  dimension: markBox,
                  child: Center(child: mark),
                ),
                const SizedBox(width: markGap),
                Expanded(child: titleText),
                ...actions,
              ],
            ),
          ),
          if (subtitle != null)
            SizedBox(
              height: subtitleRowHeight,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      subtitle,
                      key: subtitleKey,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textOnGlassDim,
                        fontSize: subtitleSize,
                      ),
                    ),
                  ),
                  if (subtitleTrailing != null) ...[
                    const SizedBox(width: 10),
                    subtitleTrailing!,
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}
