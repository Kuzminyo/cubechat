import 'package:flutter/widgets.dart';

/// A scale "pop" played when [value] changes — and, deliberately, *not* when the
/// widget is first built.
///
/// The distinction is the whole point. Every row in the message list is built
/// lazily, so a bubble scrolled back into view is a brand-new widget with brand
/// new state. Anything that animates from `initState` therefore replays itself
/// mid-scroll — the flicker [AppearAnimation] exists to avoid, and a fresh
/// ticker per row at exactly the moment the frame budget is tightest. A tick
/// turning blue or a count going 2 → 3 is worth an animation because the *fact*
/// moved; a finger dragging that same tick past is not.
///
/// [initialPop] is the escape hatch for the one case the rule gets wrong. A chip
/// that did not exist a frame ago has no previous [value] to differ from, yet
/// its arrival is exactly the change worth showing. Only the parent can tell the
/// two apart — it is the one holding the previous state, and so the only one who
/// knows whether this element is new because the list scrolled or because a
/// reaction landed — so it passes the answer down rather than having this widget
/// guess from something it cannot see.
class PopOnChange extends StatefulWidget {
  const PopOnChange({
    super.key,
    required this.value,
    required this.child,
    this.initialPop = false,
    this.peak = 1.24,
    this.duration = const Duration(milliseconds: 320),
  });

  /// Compared with `!=` against the previous build. Anything with value
  /// equality works: a status enum, a revision counter, a formatted label.
  final Object? value;

  final Widget child;

  /// Pop once on the first build too. For elements the parent knows are new
  /// *now*, rather than new because they were rebuilt.
  final bool initialPop;

  /// How far past its own size the child swells at the top of the arc.
  final double peak;

  final Duration duration;

  @override
  State<PopOnChange> createState() => _PopOnChangeState();
}

class _PopOnChangeState extends State<PopOnChange>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.duration);

  /// Out fast, back slow, and a shade under 1 before it lands.
  ///
  /// A symmetric up-and-down reads as a number being multiplied. Spending about
  /// a third of the time growing and the rest settling — with `easeOutBack` on
  /// the way down, which undershoots slightly before it arrives — is what makes
  /// it read as something with mass instead.
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween<double>(begin: 1, end: widget.peak)
          .chain(CurveTween(curve: Curves.easeOutQuad)),
      weight: 35,
    ),
    TweenSequenceItem(
      tween: Tween<double>(begin: widget.peak, end: 1)
          .chain(CurveTween(curve: Curves.easeOutBack)),
      weight: 65,
    ),
  ]).animate(_c);

  @override
  void initState() {
    super.initState();
    if (widget.initialPop) _c.forward();
  }

  @override
  void didUpdateWidget(PopOnChange old) {
    super.didUpdateWidget(old);
    // `from: 0` and not `forward()`: a second change arriving mid-pop should
    // restart the arc, not be swallowed because the controller is already at
    // the end. Two reactions landing in quick succession are two events.
    if (old.value != widget.value) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // At rest the controller sits at 0, where the sequence evaluates to exactly
    // 1 — so an idle pop costs a Transform with an identity scale and no ticker.
    return ScaleTransition(scale: _scale, child: widget.child);
  }
}
