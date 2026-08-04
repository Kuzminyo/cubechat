import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

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
///    springs back. That is the whole request, and it is not something to
///    reimplement: the route has to hand its own animation over to a drag,
///    reclaim it on release, and stay correct if a second push arrives
///    mid-gesture.
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
