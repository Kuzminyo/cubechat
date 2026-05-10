import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// Full-screen aurora gradient — base layer behind every screen.
/// Mirrors the `.tg-aurora` block from the mockup.
class AuroraBackground extends StatelessWidget {
  const AuroraBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.bgTop, AppColors.bgBottom],
        ),
      ),
      child: Stack(
        children: [
          // Aurora blobs
          const Positioned.fill(child: _AuroraBlob(alignment: Alignment(-0.7, -0.6), color: AppColors.aurora1, radius: 0.55)),
          const Positioned.fill(child: _AuroraBlob(alignment: Alignment(0.7, -0.7), color: AppColors.aurora2, radius: 0.5)),
          const Positioned.fill(child: _AuroraBlob(alignment: Alignment(0.4, 0.7), color: AppColors.aurora3, radius: 0.55)),
          const Positioned.fill(child: _AuroraBlob(alignment: Alignment(-0.6, 0.8), color: AppColors.aurora4, radius: 0.45)),
          // Slight darken pass to keep contrast
          Positioned.fill(
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.25)),
          ),
          child,
        ],
      ),
    );
  }
}

class _AuroraBlob extends StatelessWidget {
  const _AuroraBlob({required this.alignment, required this.color, required this.radius});

  final Alignment alignment;
  final Color color;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: alignment,
          radius: radius,
          colors: [color.withValues(alpha: 0.55), Colors.transparent],
        ),
      ),
    );
  }
}
