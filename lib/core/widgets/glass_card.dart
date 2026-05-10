import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// Frosted glass surface — `BackdropFilter` + soft white border.
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
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final double borderRadius;
  final bool strong;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius);
    return Padding(
      padding: margin,
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                stops: const [0.0, 0.4, 1.0],
                colors: [
                  Colors.white.withValues(alpha: strong ? 0.22 : 0.18),
                  Colors.white.withValues(alpha: 0.04),
                  Colors.white.withValues(alpha: 0.10),
                ],
              ),
              border: Border.all(
                color: strong ? AppColors.glassBorderStrong : AppColors.glassBorder,
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
