import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// Frosted glass surface — soft white border over an optional backdrop blur.
/// Matches `.glass` / `.glass-strong` from the mockup.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.borderRadius = 20,
    this.strong = false,
    this.onTap,
    this.blur = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final double borderRadius;
  final bool strong;
  final VoidCallback? onTap;

  /// Whether to sample and blur what is behind the card. See
  /// [FloatingGlass.blur] for the full argument; the short version is that a
  /// [BackdropFilter] snapshots the layer below and runs a gaussian over it,
  /// cards do not share that work, and a screen of them is one full blur pass
  /// each per frame.
  ///
  /// Defaults to **off** because every card in this app sits on the aurora —
  /// four wide radial gradients. Blurring a soft gradient returns the same soft
  /// gradient, so the pass costs a phone real heat and returns no pixels. Turn
  /// it on for a card floating over actual content, where there is detail worth
  /// softening.
  final bool blur;

  Widget _maybeBlur(Widget child) => blur
      ? BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
          child: child,
        )
      : child;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius);
    return Padding(
      padding: margin,
      child: ClipRRect(
        borderRadius: radius,
        child: _maybeBlur(
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                stops: const [0.0, 0.4, 1.0],
                colors: [
                  AppColors.glass(strong ? 0.22 : 0.18),
                  AppColors.glass(0.04),
                  AppColors.glass(0.10),
                ],
              ),
              border: Border.all(
                color: strong
                    ? AppColors.glassBorderStrong
                    : AppColors.glassBorder,
                width: 1,
              ),
              borderRadius: radius,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 24,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: radius,
                hoverColor: AppColors.glassHover,
                child: Padding(padding: padding, child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
