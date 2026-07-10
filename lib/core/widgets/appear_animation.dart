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
  });

  final Widget child;
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
