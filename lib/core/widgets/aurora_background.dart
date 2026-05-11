import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// Full-screen aurora gradient with slowly drifting blobs.
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({super.key, required this.child});

  final Widget child;

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.bgTop, AppColors.bgBottom],
          ),
        ),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = _controller.value * 2 * math.pi;
            return Stack(
              children: [
                Positioned.fill(
                  child: _AuroraBlob(
                    alignment: Alignment(
                      -0.7 + 0.25 * math.sin(t),
                      -0.6 + 0.18 * math.cos(t * 0.8),
                    ),
                    color: AppColors.aurora1,
                    radius: 0.55 + 0.05 * math.sin(t * 0.5),
                  ),
                ),
                Positioned.fill(
                  child: _AuroraBlob(
                    alignment: Alignment(
                      0.7 + 0.20 * math.cos(t * 0.7),
                      -0.7 + 0.22 * math.sin(t * 0.9),
                    ),
                    color: AppColors.aurora2,
                    radius: 0.50 + 0.05 * math.cos(t * 0.6),
                  ),
                ),
                Positioned.fill(
                  child: _AuroraBlob(
                    alignment: Alignment(
                      0.4 + 0.30 * math.sin(t * 1.1 + 1),
                      0.7 + 0.18 * math.cos(t * 0.8 + 1),
                    ),
                    color: AppColors.aurora3,
                    radius: 0.55 + 0.04 * math.sin(t * 0.7),
                  ),
                ),
                Positioned.fill(
                  child: _AuroraBlob(
                    alignment: Alignment(
                      -0.6 + 0.25 * math.cos(t * 0.9 + 2),
                      0.8 + 0.15 * math.sin(t * 0.6 + 2),
                    ),
                    color: AppColors.aurora4,
                    radius: 0.45 + 0.05 * math.cos(t * 0.85),
                  ),
                ),
                Positioned.fill(
                  child: ColoredBox(color: Colors.black.withValues(alpha: 0.28)),
                ),
                widget.child,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AuroraBlob extends StatelessWidget {
  const _AuroraBlob({
    required this.alignment,
    required this.color,
    required this.radius,
  });

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
