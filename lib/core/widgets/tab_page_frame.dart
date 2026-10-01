import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../theme/colors.dart';
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

  /// On the header's surface, drawn only while a row is under the header.
  static const veilKey = ValueKey('tab-frame-veil');

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

  /// How far below the header its surface fades out over the page.
  static const double _fade = 20;

  double get _collapse {
    if (_searchRoom == 0) return 0;
    final px = _offsets[widget.pageKey] ?? 0;
    return (px / _searchRoom).clamp(0.0, 1.0);
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical || n.depth != 0) return false;
    if (n is ScrollEndNotification) {
      _settleSearch(n);
      return false;
    }
    if (n is! ScrollUpdateNotification) return false;
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

  /// A scroll that stops part-way through the fold finishes it: back to the
  /// field if it stopped nearer that end — or if the page is too short to
  /// scroll the whole fold — else on to the button. Left where it stopped, the
  /// search sat half field, half button ("поиск залагивает"). Chats has done
  /// the same with its own search from the start.
  void _settleSearch(ScrollEndNotification n) {
    final room = _searchRoom;
    final px = n.metrics.pixels;
    if (room == 0 || px <= 0 || px >= room) return;
    final target =
        px < room / 2 || n.metrics.maxScrollExtent < room ? 0.0 : room;
    final context = n.context;
    if (context == null) return;
    final position = Scrollable.maybeOf(context)?.position;
    if (position == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !position.hasPixels) return;
      unawaited(
        position.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        ),
      );
    });
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
    // The frame starts at the top of the screen, under the status bar, the
    // way Chats' header does: the surface reaches under the clock and the
    // battery, and the header's own content starts below them. Starting the
    // whole frame below them left a band of a different colour up there once
    // the surface came in.
    final top = MediaQuery.paddingOf(context).top;
    final headerHeight = TabHeader.height + _searchRoom * (1 - collapse);
    // The page's first row starts below the search and the island; it
    // reaches the header once the page has scrolled past both.
    final px = _offsets[widget.pageKey] ?? 0;
    final veil =
        ((px - (_searchRoom + TabPageFrame.islandHeight - _fade)) / _fade)
            .clamp(0.0, 1.0);
    return ClipRect(
      child: Stack(
        children: [
          Positioned.fill(
            child: IslandInset(
              height: top +
                  TabHeader.height +
                  _searchRoom +
                  TabPageFrame.islandHeight,
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                // Ink for the pages' own buttons, the half not on show
                // included: it stays built (offstage) to keep its scroll.
                //
                // And the status bar taken away from them: the frame has
                // already allowed for it in [IslandInset], so a page that
                // also wraps itself in a SafeArea (Nearby's people page)
                // would add the same height again — a gap the size of the
                // status bar under the island.
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  child: Material(
                    type: MaterialType.transparency,
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ),
          // Under the header in paint order, so when it slides away it goes
          // behind the header's surface rather than being cut off by a line.
          Positioned(
            top: top + headerHeight,
            left: 0,
            right: 0,
            child: AnimatedSlide(
              offset: _islandShown ? Offset.zero : const Offset(0, -1),
              duration: motion,
              curve: Curves.easeOutCubic,
              // And fades as it goes: tucked behind a near-opaque surface its
              // labels still showed through faintly. Fully hidden or fully
              // shown costs nothing; only the 220 ms between is a layer.
              child: AnimatedOpacity(
                opacity: _islandShown ? 1 : 0,
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
          ),
          // Solid under the header's own text, then a short fade below it:
          // a surface that thinned out behind the subtitle let a row passing
          // under it show through the words.
          //
          // And only once a row is actually on its way under the header. Drawn
          // all the time it was a dark block with an edge across the aurora
          // at rest — "why is this here, it was beautiful, put it back" — so
          // at rest there is no surface at all, the header sits on the aurora
          // as it always did, and the surface fades in over the last [_fade]
          // points before the first row reaches the header.
          if (veil > 0)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: top + headerHeight + _fade,
              child: IgnorePointer(
                key: TabPageFrame.veilKey,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        AppColors.bgDeep.withValues(alpha: veil),
                        AppColors.bgTop.withValues(alpha: 0.96 * veil),
                        AppColors.bgTop.withValues(alpha: 0),
                      ],
                      stops: [
                        0,
                        (top + headerHeight) / (top + headerHeight + _fade),
                        1,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            top: top,
            left: 0,
            right: 0,
            height: headerHeight,
            child: Material(
              type: MaterialType.transparency,
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
