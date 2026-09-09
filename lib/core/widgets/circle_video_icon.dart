import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// A circular video camera for recording a video message in the composer.
/// The 24-unit grid and 1.65-unit stroke match the view-once outline icon.
class CircleVideoIcon extends StatelessWidget {
  const CircleVideoIcon({super.key, this.size, this.color});

  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final side = size ?? theme.size ?? 24;
    final ink = color ?? theme.color ?? AppColors.textOnGlass;
    final opacity = theme.opacity ?? 1;
    return SizedBox.square(
      dimension: side,
      child: CustomPaint(
        painter: _CircleVideoPainter(
          color: ink.withValues(alpha: ink.a * opacity),
        ),
      ),
    );
  }
}

class _CircleVideoPainter extends CustomPainter {
  const _CircleVideoPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.65
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawCircle(const Offset(9.25, 12), 7, paint);
    // The lens meets the round body at both ends, with no detached pieces.
    final lens = Path()
      ..moveTo(15.86, 9.7)
      ..lineTo(21.25, 6.8)
      ..quadraticBezierTo(22, 6.4, 22, 7.3)
      ..lineTo(22, 16.7)
      ..quadraticBezierTo(22, 17.6, 21.25, 17.2)
      ..lineTo(15.86, 14.3);
    canvas.drawPath(lens, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CircleVideoPainter oldDelegate) =>
      oldDelegate.color != color;
}
