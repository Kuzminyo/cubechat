import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Custom go_router transition — fade + subtle slide-up.
/// Tuned for glass UI: gentle, no harsh slide-from-the-side.
CustomTransitionPage<T> fadeSlidePage<T>({
  required Widget child,
  required GoRouterState state,
  Duration duration = const Duration(milliseconds: 320),
  Duration reverseDuration = const Duration(milliseconds: 240),
}) {
  return CustomTransitionPage<T>(
    key: state.pageKey,
    child: child,
    transitionDuration: duration,
    reverseTransitionDuration: reverseDuration,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      final secondaryCurved = CurvedAnimation(
        parent: secondaryAnimation,
        curve: Curves.easeInOutCubic,
      );

      final slide = Tween<Offset>(
        begin: const Offset(0, 0.04),
        end: Offset.zero,
      ).animate(curved);

      // Parent screen drifts up + fades slightly when a child route pushes on top
      final parentSlide = Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(0, -0.02),
      ).animate(secondaryCurved);
      final parentFade = Tween<double>(begin: 1.0, end: 0.85).animate(secondaryCurved);

      return SlideTransition(
        position: parentSlide,
        child: FadeTransition(
          opacity: parentFade,
          child: FadeTransition(
            opacity: curved,
            child: SlideTransition(position: slide, child: child),
          ),
        ),
      );
    },
  );
}
