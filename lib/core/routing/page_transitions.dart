import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// How a pushed screen arrives and leaves.
///
/// Sideways, not upward. The tabs became a strip you drag between, and a chat
/// opened from that strip belongs to the same geography: it comes in from the
/// right, over a list that steps back rather than staying nailed in place, and
/// it leaves the way it came. Fading a screen up from below made every push
/// read as a modal — something appearing *over* the app rather than the next
/// thing along in it.
///
/// The outgoing screen only travels a quarter of the width. Moving it the full
/// distance would say the two are side by side, which is what the tab strip
/// says and this is not: you can come back from here, and the screen you came
/// from is still underneath.
CustomTransitionPage<T> fadeSlidePage<T>({
  required Widget child,
  required GoRouterState state,
  Duration duration = const Duration(milliseconds: 300),
  Duration reverseDuration = const Duration(milliseconds: 260),
}) {
  return CustomTransitionPage<T>(
    key: state.pageKey,
    child: child,
    transitionDuration: duration,
    reverseTransitionDuration: reverseDuration,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      // easeOutCubic in, easeInCubic out — the same pair the tab strip settles
      // on, so the whole app decelerates alike.
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      final secondaryCurved = CurvedAnimation(
        parent: secondaryAnimation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );

      final incoming = Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(curved);

      // What is left behind: a short step back and a little darker, so the
      // arriving screen has something to arrive in front of.
      final outgoing = Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(-0.25, 0),
      ).animate(secondaryCurved);
      final outgoingFade =
          Tween<double>(begin: 1, end: 0.7).animate(secondaryCurved);

      return SlideTransition(
        position: outgoing,
        child: FadeTransition(
          opacity: outgoingFade,
          child: SlideTransition(
            position: incoming,
            // Only the first stretch of the travel carries a fade, so the
            // screen is not translucent while it moves — a solid thing sliding
            // in, rather than two images being mixed.
            child: FadeTransition(
              opacity: Tween<double>(begin: 0.5, end: 1).animate(
                CurvedAnimation(
                  parent: animation,
                  curve: const Interval(0, 0.45, curve: Curves.easeOut),
                ),
              ),
              child: child,
            ),
          ),
        ),
      );
    },
  );
}

/// How a full-screen picture opens: a fade with a whisper of scale, the same
/// timings as [fadeSlidePage].
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
