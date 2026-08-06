import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'back_gesture.dart';

/// How a pushed screen arrives, leaves, and is dragged back.
///
/// This is Cupertino's page transition, on both platforms and deliberately.
/// Not for the look — the slide it gives is the one this app already wanted,
/// sideways with the screen underneath stepping back — but for the two things
/// a hand-rolled `CustomTransitionPage` cannot have:
///
///  * **A back gesture.** Pull from the left edge and the screen follows the
///    finger, at the distance the finger put it, and the one underneath comes
///    forward with it. Let go past halfway and it leaves; let go short and it
///    springs back. The transition machinery for that is worth not
///    reimplementing: the route has to hand its own animation over to a drag,
///    reclaim it on release, and stay correct if a second push arrives
///    mid-gesture. The *detector* is replaced — see [EdgeBackGesture] for why
///    Flutter's 20-pixel strip is unreachable on an Android phone.
///  * **Interruptibility.** A tween driven by a fixed-duration controller
///    cannot be caught halfway; every "jumpy" transition in this app was one of
///    those being restarted from wherever it happened to be.
///
/// The name stays [fadeSlidePage] because forty call sites use it and none of
/// them care how it moves.
Page<T> fadeSlidePage<T>({
  required Widget child,
  required GoRouterState state,
  Duration? duration,
  Duration? reverseDuration,
}) {
  return _SlidePage<T>(key: state.pageKey, child: child);
}

/// Cupertino's route, at this app's pace.
///
/// [CupertinoPage] would do everything here except the timing: iOS spends
/// 400 ms on a push, which next to a 240 ms tab strip and a 260 ms sheet reads
/// as the app hesitating. Everything else — the parallax, the shadow on the
/// leading edge, the edge-drag that hands the animation to your thumb — comes
/// from the mixin, because those are the parts worth not reimplementing.
class _SlidePage<T> extends Page<T> {
  const _SlidePage({required this.child, super.key});

  final Widget child;

  @override
  Route<T> createRoute(BuildContext context) => _SlideRoute<T>(page: this);
}

class _SlideRoute<T> extends PageRoute<T> with CupertinoRouteTransitionMixin<T> {
  _SlideRoute({required _SlidePage<T> page}) : super(settings: page);

  @override
  Widget buildContent(BuildContext context) => (settings as _SlidePage<T>).child;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  String? get title => null;

  @override
  bool get maintainState => true;

  /// The mixin's own transition, with a reachable drag strip in place of its
  /// 20-pixel one.
  ///
  /// [CupertinoPageTransition] is kept exactly as it is — the parallax, the
  /// shadow on the leading edge, and `linearTransition`, which is what makes
  /// the page track the finger instead of easing while it is being dragged.
  /// Only the detector changes, because that is where the problem was: a strip
  /// too narrow to hit, in the one place Android's own gesture navigation
  /// already takes the touch. See [EdgeBackGesture].
  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return CupertinoPageTransition(
      primaryRouteAnimation: animation,
      secondaryRouteAnimation: secondaryAnimation,
      linearTransition: popGestureInProgress,
      child: _RoundedWhileMoving(
        primary: animation,
        secondary: secondaryAnimation,
        child: EdgeBackGesture(
          enabledCallback: () => popGestureEnabled,
          onStartGesture: () => EdgeBackGestureController(
            navigator: navigator!,
            controller: controller!,
            isCurrent: () => isCurrent,
            isActive: () => isActive,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Rounds a page's corners for exactly as long as it is moving.
///
/// A screen sliding over another with square corners reads as one flat thing
/// being replaced by another flat thing. Rounded while it travels — and rounded
/// on the page underneath as it recedes — the two read as sheets, one lifted
/// over the other, which is the whole feeling of dragging one back with a
/// thumb.
///
/// Costs nothing at rest, deliberately. A clip is not free: it forces a save
/// layer for everything inside it, on every frame, on the most-scrolled screens
/// in the app. So the radius is a function of how far the page is from settled
/// — [primary] below 1 while it arrives or leaves, [secondary] above 0 while
/// something covers it — and at zero radius the clip is not built at all.
class _RoundedWhileMoving extends StatelessWidget {
  const _RoundedWhileMoving({
    required this.primary,
    required this.secondary,
    required this.child,
  });

  final Animation<double> primary;
  final Animation<double> secondary;
  final Widget child;

  static const double _radius = 22;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([primary, secondary]),
      child: child,
      builder: (context, inner) {
        final travelling = math.max(
          1 - primary.value.clamp(0.0, 1.0),
          secondary.value.clamp(0.0, 1.0),
        );
        final radius = _radius * travelling;
        if (radius < 0.5) return inner!;
        return ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: inner,
        );
      },
    );
  }
}

/// How a full-screen picture opens: a fade with a whisper of scale.
///
/// Not a side-slide — a photo, the editor and the camera are not "the next
/// screen along", they are the same thing at a different size, and sliding one
/// in from the edge says otherwise. What they must not do is what they did:
/// appear and vanish outright, which is the closing everyone described as
/// abrupt because there was nothing there at all.
PageRoute<T> mediaRoute<T>(WidgetBuilder builder) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 300),
    reverseTransitionDuration: const Duration(milliseconds: 260),
    opaque: false,
    barrierColor: Colors.black,
    pageBuilder: (context, animation, secondary) => builder(context),
    transitionsBuilder: (context, animation, secondary, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}
