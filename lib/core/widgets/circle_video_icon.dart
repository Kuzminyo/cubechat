import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// The mark on the composer button that records a circle.
///
/// A front camera: a square body with a lens in it, the way the camera on the
/// side of the phone you point at yourself is drawn everywhere.
///
/// **Filled, not outlined.** It was an outline first, on the same 24-unit grid
/// and 1.65-unit stroke as the view-once mark — which is right for that one,
/// drawn at 20 points inside a large chip. This sits at 22 points on a 44-point
/// disc beside a solid microphone, and at that size a hairline outline reads as
/// a wireframe of an icon rather than an icon: reported, accurately, as looking
/// like a mock-up. The microphone it alternates with is a filled Material glyph
/// and the two have to weigh the same, or the button appears to lose substance
/// every time it turns over.
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
      ..isAntiAlias = true;

    // The body: a rounded square, filled, with the lens knocked out of it
    // rather than drawn on top. One path with two contours and the even-odd
    // rule, so the hole is a hole at any size — a second circle painted in the
    // background colour would show the wrong colour over a photograph.
    final body = Path()
      ..fillType = PathFillType.evenOdd
      ..addRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(3, 4.5, 18, 15),
          const Radius.circular(4.2),
        ),
      )
      ..addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 4.15));
    canvas.drawPath(body, paint);

    // The lens, back inside the hole, leaving a ring of body around it. This
    // is what makes it a camera pointed at you rather than a picture frame.
    canvas.drawCircle(const Offset(12, 12), 2.35, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CircleVideoPainter oldDelegate) =>
      oldDelegate.color != color;
}
