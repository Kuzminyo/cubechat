import 'package:flutter/material.dart';

/// Palette extracted from the Cubegram glass mockup.
abstract final class AppColors {
  // Base background
  static Color bgDeep = Color(0xFF06140D);
  static Color bgTop = Color(0xFF0D2818);
  static Color bgBottom = Color(0xFF0A3D28);

  // Aurora accents
  static Color aurora1 = Color(0xFF2EDB8F);
  static Color aurora2 = Color(0xFF7FD9A6);
  static Color aurora3 = Color(0xFF34D399);
  static Color aurora4 = Color(0xFFA3E635);

  // Primary brand
  static Color brandPrimary = Color(0xFF2EDB8F);
  static Color brandSecondary = Color(0xFF7FD9A6);
  static LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [brandPrimary, brandSecondary],
  );

  // Glass surface tints (white at varying opacity)
  static Color glassFill = Colors.white.withValues(alpha: 0.08);
  static Color glassFillStrong = Colors.white.withValues(alpha: 0.12);
  static Color glassBorder = Colors.white.withValues(alpha: 0.18);
  static Color glassBorderStrong = Colors.white.withValues(alpha: 0.22);
  static Color glassHover = Colors.white.withValues(alpha: 0.06);

  // Text
  static const Color textPrimary = Color(0xFFE8E8F0);
  static Color textOnGlass = Colors.white.withValues(alpha: 0.95);
  static Color textOnGlassDim = Colors.white.withValues(alpha: 0.6);
  static Color textOnGlassFaint = Colors.white.withValues(alpha: 0.4);

  // Semantic
  static const Color danger = Color(0xFFFF5A6B);
  static const Color warning = Color(0xFFF5C26B);
  static Color online = Color(0xFF2EDB8F);
}
