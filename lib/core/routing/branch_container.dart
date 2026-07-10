import 'package:flutter/material.dart';

/// Container for the tab-shell branches.
///
/// Every branch stays mounted for the life of the shell, so switching tabs
/// costs nothing: no rebuild, no re-run of entrance animations, and scroll
/// positions survive. The only thing that animates is a short cross-fade
/// between the outgoing and incoming branch.
///
/// An inactive branch is taken [Offstage] once its fade-out finishes — it keeps
/// its state but is skipped during layout and paint, so three screens' worth of
/// blurred glass isn't being rasterised behind the one you're looking at.
class BranchContainer extends StatelessWidget {
  const BranchContainer({
    super.key,
    required this.currentIndex,
    required this.branches,
  });

  final int currentIndex;
  final List<Widget> branches;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < branches.length; i++)
          _Branch(active: i == currentIndex, child: branches[i]),
      ],
    );
  }
}

class _Branch extends StatefulWidget {
  const _Branch({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<_Branch> createState() => _BranchState();
}

class _BranchState extends State<_Branch> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 190),
    reverseDuration: const Duration(milliseconds: 140),
    value: widget.active ? 1 : 0,
  );

  late final Animation<double> _fade =
      CurvedAnimation(parent: _c, curve: Curves.easeOut);

  // A whisper of scale on the way in — enough to read as "arriving" without
  // looking like a zoom.
  late final Animation<double> _scale =
      Tween<double>(begin: 0.985, end: 1).animate(_fade);

  @override
  void didUpdateWidget(covariant _Branch old) {
    super.didUpdateWidget(old);
    if (widget.active != old.active) {
      if (widget.active) {
        _c.forward();
      } else {
        _c.reverse();
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        // Fully faded out and not the active branch → stop drawing it, but keep
        // it in the tree so its state (and scroll offset) survives.
        final hidden = !widget.active && _c.isDismissed;
        return Offstage(
          offstage: hidden,
          child: IgnorePointer(
            ignoring: !widget.active,
            // Silences tickers inside the branch (aurora, entrance animations)
            // while it isn't on screen.
            child: TickerMode(
              enabled: widget.active,
              child: FadeTransition(
                opacity: _fade,
                child: ScaleTransition(scale: _scale, child: child),
              ),
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}
