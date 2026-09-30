import 'package:flutter/material.dart';

/// How far down a page under a [ScrollHidingIsland] has to start its list, so
/// its first row sits below the island rather than under it.
///
/// Zero where there is no island, so a page reads it unconditionally.
class IslandInset extends InheritedWidget {
  const IslandInset({super.key, required this.height, required super.child});

  final double height;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<IslandInset>()?.height ?? 0;

  @override
  bool updateShouldNotify(IslandInset old) => old.height != height;
}

/// An island (a section switch) floating over the top of a scrolling page,
/// that slides away while you scroll down and comes back the moment you
/// scroll up.
///
/// Over the page, not above it. Collapsing a slot above the list would pull
/// the list up by the island's height in the middle of a scroll and push it
/// back down when the island returned — the jump this was built to avoid. The
/// page instead starts its list [islandHeight] down (see [IslandInset]) and
/// scrolls under the island; the island moves, the list does not.
class ScrollHidingIsland extends StatefulWidget {
  const ScrollHidingIsland({
    super.key,
    required this.island,
    required this.islandHeight,
    required this.child,
    this.showKey,
  });

  final Widget island;
  final double islandHeight;
  final Widget child;

  /// Changing this brings the island back — a different page underneath has
  /// its own scroll position, and a hidden switch would leave no way back.
  final Object? showKey;

  @override
  State<ScrollHidingIsland> createState() => _ScrollHidingIslandState();
}

class _ScrollHidingIslandState extends State<ScrollHidingIsland> {
  bool _shown = true;

  /// Travel up needed to bring it back: past a jitter, well short of a flick.
  static const double _upToShow = 2;

  void _set(bool shown) {
    if (shown != _shown) setState(() => _shown = shown);
  }

  bool _onScroll(ScrollUpdateNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    final delta = n.scrollDelta ?? 0;
    if (n.metrics.pixels <= 0) {
      _set(true);
    } else if (delta > 0 && n.metrics.pixels > widget.islandHeight) {
      _set(false);
    } else if (delta < -_upToShow) {
      _set(true);
    }
    return false;
  }

  @override
  void didUpdateWidget(ScrollHidingIsland old) {
    super.didUpdateWidget(old);
    if (old.showKey != widget.showKey) _shown = true;
  }

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    return ClipRect(
      child: Stack(
        children: [
          Positioned.fill(
            child: IslandInset(
              height: widget.islandHeight,
              child: NotificationListener<ScrollUpdateNotification>(
                onNotification: _onScroll,
                child: widget.child,
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AnimatedSlide(
              offset: _shown ? Offset.zero : const Offset(0, -1),
              duration: duration,
              curve: Curves.easeOutCubic,
              child: IgnorePointer(ignoring: !_shown, child: widget.island),
            ),
          ),
        ],
      ),
    );
  }
}
