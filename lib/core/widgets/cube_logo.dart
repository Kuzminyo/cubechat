import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/theme_controller.dart';

/// The cubechat logo — an isometric 3D cube rendered programmatically.
///
/// Painter-first by design: there's no PNG dependency for in-app use, the
/// cube scales crisply at every size, and the colour palette stays in lock-
/// step with the brand (no asset to keep in sync).
///
/// For launcher icons / splash screens, run `tool/export_logo.dart` once —
/// it rasterizes [CubeLogoPainter] to `assets/logo/cube.png` at 1024×1024.
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
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: CubeLogoPainter(glow: glow)),
    );
  }
}

/// Stand-alone painter so the export tool can reuse it.
class CubeLogoPainter extends CustomPainter {
  CubeLogoPainter({
    this.glow = true,
    Color? primary,
    Color? secondary,
  })  : primary = primary ?? AppColors.brandPrimary,
        secondary = secondary ?? AppColors.brandSecondary;

  final bool glow;

  /// The palette's brand colours, captured when the painter is built rather
  /// than read in [paint]: [AppColors] is mutated in place when a palette is
  /// chosen, so only a value held here lets [shouldRepaint] see the change.
  final Color primary;
  final Color secondary;
  static const _cos30 = 0.86602540378;

  @override
  void paint(Canvas canvas, Size size) {
    final faces = CubeFaces.of(primary, secondary);
    final topBright = faces.topBright;
    final topDark = faces.topDark;
    final rightBright = faces.rightBright;
    final rightDark = faces.rightDark;
    final leftBright = faces.leftBright;
    final leftDark = faces.leftDark;
    final seam = faces.seam;
    final cx = size.width / 2;
    final cy = size.height / 2;
    // Cube spans 2 * scale vertically (apex to apex) and 2 * scale * cos30 horizontally.
    final scale = math.min(size.width, size.height) * 0.38;

    Offset p(double nx, double ny) => Offset(cx + nx * scale, cy + ny * scale);

    // Seven visible vertices of the isometric cube.
    final topApex = p(0, -1.0);
    final rightBack = p(_cos30, -0.5);
    final leftBack = p(-_cos30, -0.5);
    final centerFront = p(0, 0); // where 3 faces meet
    final rightBottom = p(_cos30, 0.5);
    final leftBottom = p(-_cos30, 0.5);
    final bottomApex = p(0, 1.0);

    // ----- Drop shadow under the cube -----
    final shadowRect = Rect.fromCenter(
      center: Offset(cx, cy + scale * 1.15),
      width: scale * 1.7,
      height: scale * 0.32,
    );
    canvas.drawOval(
      shadowRect,
      Paint()
        ..color = const Color(0xFF000000).withValues(alpha: 0.28)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, scale * 0.18),
    );

    // ----- Soft outer glow (the brand halo) -----
    if (glow) {
      canvas.drawCircle(
        Offset(cx, cy),
        scale * 0.9,
        Paint()
          ..color = primary.withValues(alpha: 0.22)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, scale * 0.45),
      );
    }

    // ----- TOP face (lit from above, brightest) -----
    final topPath = _quad([topApex, rightBack, centerFront, leftBack]);
    canvas.drawPath(
      topPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [topBright, topDark],
        ).createShader(topPath.getBounds()),
    );

    // ----- RIGHT face (medium, side-lit) -----
    final rightPath = _quad([rightBack, rightBottom, bottomApex, centerFront]);
    canvas.drawPath(
      rightPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [rightBright, rightDark],
        ).createShader(rightPath.getBounds()),
    );

    // ----- LEFT face (shadow side, deepest) -----
    final leftPath = _quad([leftBack, centerFront, bottomApex, leftBottom]);
    canvas.drawPath(
      leftPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [leftBright, leftDark],
        ).createShader(leftPath.getBounds()),
    );

    // ----- Edge highlights (the lit edges catch a thin specular line) -----
    final edgeStroke = math.max(1.0, scale * 0.025);

    // Top-face rim — strongest highlight
    canvas.drawLine(
      topApex,
      rightBack,
      Paint()
        ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.55)
        ..strokeWidth = edgeStroke
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      topApex,
      leftBack,
      Paint()
        ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.35)
        ..strokeWidth = edgeStroke
        ..strokeCap = StrokeCap.round,
    );

    // Front vertical edge — the cube's "front spine"
    canvas.drawLine(
      centerFront,
      bottomApex,
      Paint()
        ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.18)
        ..strokeWidth = edgeStroke * 0.7
        ..strokeCap = StrokeCap.round,
    );

    // ----- Inner separators (subtle dark lines where faces meet) -----
    final innerSeam = Paint()
      ..color = seam
      ..strokeWidth = edgeStroke * 0.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(centerFront, rightBack, innerSeam);
    canvas.drawLine(centerFront, leftBack, innerSeam);

    // ----- Specular highlight on the top face (small soft spot) -----
    if (glow) {
      final highlight = Rect.fromCenter(
        center: Offset(cx + scale * 0.18, cy - scale * 0.55),
        width: scale * 0.5,
        height: scale * 0.22,
      );
      canvas.drawOval(
        highlight,
        Paint()
          ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.45)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, scale * 0.10),
      );
    }
  }

  Path _quad(List<Offset> pts) {
    final p = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (var i = 1; i < pts.length; i++) {
      p.lineTo(pts[i].dx, pts[i].dy);
    }
    return p..close();
  }

  @override
  bool shouldRepaint(covariant CubeLogoPainter old) =>
      old.glow != glow || old.primary != primary || old.secondary != secondary;
}

/// The colours of the cube's three faces and the seam between them.
///
/// Emerald keeps the hand-picked lime faces the mark has always had: they are
/// what `tool/export_logo.dart` rasterised into the default launcher icon, and
/// deriving them from Emerald's mint `brandPrimary` instead turned the in-app
/// logo a different green from the icon on the home screen — and would have
/// changed the icon itself on the next export. Every other palette derives its
/// faces from its own two brand colours, which is also how the per-theme
/// launcher icons were drawn.
@immutable
class CubeFaces {
  const CubeFaces({
    required this.topBright,
    required this.topDark,
    required this.rightBright,
    required this.rightDark,
    required this.leftBright,
    required this.leftDark,
    required this.seam,
  });

  factory CubeFaces.of(Color primary, Color secondary) {
    if (primary == AppPalette.emerald.brandPrimary &&
        secondary == AppPalette.emerald.brandSecondary) {
      return classic;
    }
    return CubeFaces(
      topBright: _lighten(secondary, 0.34),
      topDark: _lighten(primary, 0.16),
      rightBright: _lighten(primary, 0.06),
      rightDark: _darken(primary, 0.28),
      leftBright: _darken(primary, 0.12),
      leftDark: _darken(primary, 0.52),
      seam: _darken(primary, 0.72).withValues(alpha: 0.35),
    );
  }

  /// The original mark, unchanged since the logo was first drawn.
  static const classic = CubeFaces(
    topBright: Color(0xFFCFFC56),
    topDark: Color(0xFFA3E635),
    rightBright: Color(0xFF7BC93C),
    rightDark: Color(0xFF4C9B23),
    leftBright: Color(0xFF5BAE2C),
    leftDark: Color(0xFF2D7211),
    seam: Color(0x591B4D0A), // 0xFF1B4D0A at 0.35
  );

  final Color topBright;
  final Color topDark;
  final Color rightBright;
  final Color rightDark;
  final Color leftBright;
  final Color leftDark;
  final Color seam;

  static Color _lighten(Color color, double amount) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness(
          math.min(1, hsl.lightness + (1 - hsl.lightness) * amount).toDouble(),
        )
        .toColor();
  }

  static Color _darken(Color color, double amount) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness(math.max(0, hsl.lightness * (1 - amount)).toDouble())
        .toColor();
  }
}
