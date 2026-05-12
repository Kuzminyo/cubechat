import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// The cubechat logo. Loads `assets/logo/cube.png` and adds a subtle
/// brand-coloured glow underneath so it sits well on the aurora background.
class CubeLogo extends StatelessWidget {
  const CubeLogo({
    super.key,
    this.size = 28,
    this.glow = true,
  });

  final double size;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      'assets/logo/cube.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, __, ___) => _Placeholder(size: size),
    );

    if (!glow) return image;

    return DecoratedBox(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: AppColors.brandPrimary.withValues(alpha: 0.25),
            blurRadius: size * 0.5,
            spreadRadius: -size * 0.05,
          ),
        ],
      ),
      child: image,
    );
  }
}

/// Vector fallback when the asset hasn't been dropped in yet. Looks like a
/// stylised isometric cube so the layout doesn't shift after the real file
/// lands.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _CubePainter()),
    );
  }
}

class _CubePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final top = Path()
      ..moveTo(w * 0.5, h * 0.1)
      ..lineTo(w * 0.92, h * 0.32)
      ..lineTo(w * 0.5, h * 0.55)
      ..lineTo(w * 0.08, h * 0.32)
      ..close();
    final left = Path()
      ..moveTo(w * 0.08, h * 0.32)
      ..lineTo(w * 0.5, h * 0.55)
      ..lineTo(w * 0.5, h * 0.95)
      ..lineTo(w * 0.08, h * 0.72)
      ..close();
    final right = Path()
      ..moveTo(w * 0.92, h * 0.32)
      ..lineTo(w * 0.5, h * 0.55)
      ..lineTo(w * 0.5, h * 0.95)
      ..lineTo(w * 0.92, h * 0.72)
      ..close();

    canvas.drawPath(top, Paint()..color = AppColors.aurora4);
    canvas.drawPath(left, Paint()..color = AppColors.aurora1);
    canvas.drawPath(right, Paint()..color = AppColors.aurora3);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
