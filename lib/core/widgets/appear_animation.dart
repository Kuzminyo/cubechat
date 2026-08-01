import 'package:flutter/material.dart';

/// Slide-up + fade entrance animation, driven by a delay-aware controller.
class AppearAnimation extends StatefulWidget {
  const AppearAnimation({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 360),
    this.beginOffset = const Offset(0, 0.08),
    this.curve = Curves.easeOutCubic,
    this.enabled = true,
  });

  final Widget child;

  /// Whether to animate at all.
  ///
  /// A list builds its rows lazily, so a row scrolled into view is a *new*
  /// widget — and it would play the entrance again, mid-scroll. That is both a
  /// flicker where there should be none and a fresh ticker per row at exactly
  /// the moment the frame budget is tightest. Lists pass false once their first
  /// frame is on screen: the flourish belongs to the list arriving, not to
  /// every row the finger drags past.
  final bool enabled;

  final Duration delay;
  final Duration duration;
  final Offset beginOffset;
  final Curve curve;

  /// Entrance delay for the [index]-th item of a list.
  ///
  /// The stagger is capped: past [maxSteps] every item shares the last delay,
  /// so a long list finishes arriving in a fixed ~150 ms instead of trickling
  /// in for most of a second. The cascade is a flourish on the first few rows,
  /// not a loading bar.
  static Duration stagger(int index, {int stepMs = 26, int maxSteps = 6}) =>
      Duration(milliseconds: stepMs * (index < maxSteps ? index : maxSteps));

  @override
  State<AppearAnimation> createState() => _AppearAnimationState();
}

class _AppearAnimationState extends State<AppearAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.duration);

  late final Animation<double> _opacity =
      CurvedAnimation(parent: _c, curve: widget.curve);

  late final Animation<Offset> _offset = Tween<Offset>(
    begin: widget.beginOffset,
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _c, curve: widget.curve));

  @override
  void initState() {
    super.initState();
    if (!widget.enabled) {
      // Straight to the end state: no ticker, no delayed callback, and the row
      // is simply there.
      _c.value = 1;
      return;
    }
    if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      Future<void>.delayed(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _offset, child: widget.child),
    );
  }
}

/// Turns [AppearAnimation] off once the list it wraps has had its first frame.
///
/// Without this every row scrolled into view replays the entrance, because a
/// lazily-built list makes a *new* widget for it. Wrapping the list once is
/// less error-prone than threading a flag through every builder, and it keeps
/// the rule in one place: the flourish belongs to the list arriving.
class AppearOnce extends StatefulWidget {
  const AppearOnce({super.key, required this.builder});

  final Widget Function(BuildContext context, bool animate) builder;

  @override
  State<AppearOnce> createState() => _AppearOnceState();
}

class _AppearOnceState extends State<AppearOnce> {
  bool _animate = true;

  @override
  void initState() {
    super.initState();
    // After the first frame the visible rows have already been built and are
    // playing their entrance; everything built from here on is the result of
    // scrolling.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _animate) setState(() => _animate = false);
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _animate);
}
