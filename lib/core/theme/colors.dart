import 'package:flutter/material.dart';

/// Palette extracted from the Cubegram glass mockup.
///
/// Every field here is mutable and rewritten by `ThemeController` when a
/// palette is chosen — see that class for why the colours are pushed into
/// statics instead of down through a `Theme`.
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

  /// What "white" means for a pane of glass under the current palette.
  ///
  /// Every surface in the app is white at some low opacity over the aurora, and
  /// for a long time that was literally `Colors.white` — which is why changing
  /// the palette moved the accents and left the interface itself the same grey
  /// it always was. This is white pulled some way toward the palette's tint, so
  /// a rose theme is genuinely a rose interface rather than a grey one with
  /// pink buttons. Rewritten by `ThemeController`; call it through [glass].
  static Color glassBase = Colors.white;

  /// The same idea for text and icons, tinted far more lightly — legibility is
  /// the point of a label, and a saturated one reads as a link.
  static Color inkBase = Colors.white;

  /// A glass surface at [alpha]: fills, borders, dividers, scrims.
  static Color glass(double alpha) => glassBase.withValues(alpha: alpha);

  /// Text or an icon at [alpha], over glass.
  static Color ink(double alpha) => inkBase.withValues(alpha: alpha);

  // Glass surface tints (the palette's white at varying opacity)
  static Color glassFill = Colors.white.withValues(alpha: 0.08);
  static Color glassFillStrong = Colors.white.withValues(alpha: 0.12);
  static Color glassBorder = Colors.white.withValues(alpha: 0.18);
  static Color glassBorderStrong = Colors.white.withValues(alpha: 0.22);
  static Color glassHover = Colors.white.withValues(alpha: 0.06);

  // Text
  static Color textPrimary = Color(0xFFE8E8F0);
  static Color textOnGlass = Colors.white.withValues(alpha: 0.95);
  static Color textOnGlassDim = Colors.white.withValues(alpha: 0.6);
  static Color textOnGlassFaint = Colors.white.withValues(alpha: 0.4);

  // Semantic
  static const Color danger = Color(0xFFFF5A6B);
  static const Color warning = Color(0xFFF5C26B);
  static Color online = Color(0xFF2EDB8F);
}
