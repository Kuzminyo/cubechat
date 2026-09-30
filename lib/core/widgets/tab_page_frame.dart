import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'header_surface.dart';
import 'morphing_search.dart';
import 'scroll_hiding_island.dart';
import 'section_switch.dart';
import 'tab_header.dart';

/// The search a [TabPageFrame] folds into a button.
class TabFrameSearch {
  const TabFrameSearch({required this.hint, required this.onTap, this.field});

  final String hint;

  /// Tapped as a button — folded, or a field with nothing to type into.
  final VoidCallback onTap;

  /// A text field, for a search that filters in place (Contacts). Without
  /// one the search is a button that opens something (Chats' search screen).
  final Widget? field;
}

/// A tab's header drawn over its pages, the way Chats has always drawn its
/// own: the title, a search that folds into a round button as the page
/// scrolls, and the section island, which slides away under the header on
/// the way down and comes back on the slightest scroll up.
///
/// Over the pages, not above them. A page starts its list below all of it
/// (see [IslandInset]) and scrolls underneath; the header only changes what is
/// drawn on top. So nothing under the finger ever moves by anything but the
/// finger — the header folding does not pull the list, and the island
/// arriving does not push it. And rows pass under the header's soft surface
/// instead of being cut off by a line under the subtitle, which is what
/// "Nearby's header is chopped" was.
class TabPageFrame extends StatefulWidget {
  const TabPageFrame({
    super.key,
    required this.header,
    required this.island,
    required this.pageKey,
    required this.child,
    this.search,
    this.trailingActionsWidth = 0,
  });

  /// A [TabHeader]. When there is a [search], its actions must begin with a
  /// gap of [searchSlot] for the folded button to land in.
  final Widget header;
  final TabFrameSearch? search;

  /// Width of the header buttons to the right of the folded search.
  final double trailingActionsWidth;

  final Widget island;

  /// The page on show. Changing it brings the island back and sets the
  /// search to that page's own scroll position.
  final Object pageKey;

  final Widget child;

  static const double searchGap = 14;
  static const double searchHeight = 46;
  static const double searchRoom = searchGap + searchHeight;
  static const double bubble = 42;

  /// The gap a header keeps for the folded search, so the title never shuffles
  /// sideways as it arrives.
  static const double searchSlot = bubble + 6;

  static const double sidePadding = 16;
  static const double islandTop = 14;
  static const double islandBottom = 16;

  /// The island's slot: the switch and the space around it.
  static const double islandHeight =
      islandTop + SectionSwitch.height + islandBottom;

  /// On the search, so a test can find where it landed.
  static const searchKey = ValueKey('tab-frame-search');

  @override
  State<TabPageFrame> createState() => _TabPageFrameState();
}

class _TabPageFrameState extends State<TabPageFrame> {
  /// Each page's last scroll position, so switching back to a scrolled page
  /// shows its search folded rather than unfolding over it.
  final Map<Object, double> _offsets = {};
  bool _islandShown = true;

  /// True for the switch itself: the fold eases to the new page's position
  /// instead of snapping; while scrolling it follows the finger exactly.
  bool _easing = false;

  double get _searchRoom =>
      widget.search == null ? 0 : TabPageFrame.searchRoom;

  double get _collapse {
    if (_searchRoom == 0) return 0;
    final px = _offsets[widget.pageKey] ?? 0;
    return (px / _searchRoom).clamp(0.0, 1.0);
  }

  bool _onScroll(ScrollUpdateNotification n) {
    if (n.metrics.axis != Axis.vertical || n.depth != 0) return false;
    final px = n.metrics.pixels;
    final delta = n.scrollDelta ?? 0;
    setState(() {
      _easing = false;
      _offsets[widget.pageKey] = px;
      if (px <= _searchRoom) {
        _islandShown = true;
      } else if (delta > 0 && px > _searchRoom + TabPageFrame.islandHeight) {
        _islandShown = false;
      } else if (delta < -2) {
        _islandShown = true;
      }
    });
    return false;
  }

  @override
  void didUpdateWidget(TabPageFrame old) {
    super.didUpdateWidget(old);
    if (old.pageKey != widget.pageKey) {
      _islandShown = true;
      _easing = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final motion = reduced ? Duration.zero : const Duration(milliseconds: 220);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: _collapse),
      duration: _easing ? motion : Duration.zero,
      curve: Curves.easeOutCubic,
      builder: (context, collapse, _) => _layout(context, collapse, motion),
    );
  }

  Widget _layout(BuildContext context, double collapse, Duration motion) {
    final headerHeight = TabHeader.height + _searchRoom * (1 - collapse);
    return ClipRect(
      child: Stack(
        children: [
          Positioned.fill(
            child: IslandInset(
              height:
                  TabHeader.height + _searchRoom + TabPageFrame.islandHeight,
              child: NotificationListener<ScrollUpdateNotification>(
                onNotification: _onScroll,
                child: widget.child,
              ),
            ),
          ),
          // Under the header in paint order, so when it slides away it goes
          // behind the header's surface rather than being cut off by a line.
          Positioned(
            top: headerHeight,
            left: 0,
            right: 0,
            child: AnimatedSlide(
              offset: _islandShown ? Offset.zero : const Offset(0, -1),
              duration: motion,
              curve: Curves.easeOutCubic,
              child: IgnorePointer(
                ignoring: !_islandShown,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    TabPageFrame.sidePadding,
                    TabPageFrame.islandTop,
                    TabPageFrame.sidePadding,
                    TabPageFrame.islandBottom,
                  ),
                  child: widget.island,
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: headerHeight,
            child: HeaderSurface(
              softBottom: true,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  widget.header,
                  if (widget.search != null)
                    _search(context, collapse, widget.search!),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _search(BuildContext context, double collapse, TabFrameSearch s) {
    final t = Curves.easeOutCubic.transform(collapse);
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        const pad = TabPageFrame.sidePadding;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: lerpDouble(
                pad,
                width -
                    TabHeader.sidePadding -
                    widget.trailingActionsWidth -
                    TabPageFrame.bubble -
                    2,
                t,
              ),
              top: lerpDouble(
                TabHeader.height + TabPageFrame.searchGap,
                TabHeader.topPadding +
                    (TabHeader.rowHeight - TabPageFrame.bubble) / 2,
                t,
              ),
              width: lerpDouble(width - pad * 2, TabPageFrame.bubble, t),
              height: lerpDouble(
                TabPageFrame.searchHeight,
                TabPageFrame.bubble,
                t,
              ),
              child: MorphingSearch(
                key: TabPageFrame.searchKey,
                radius: lerpDouble(16, TabPageFrame.bubble / 2, t)!,
                collapse: t,
                hint: s.hint,
                onTap: s.onTap,
                field: s.field,
                iconKey: const ValueKey('tab-frame-search-icon'),
              ),
            ),
          ],
        );
      },
    );
  }
}
