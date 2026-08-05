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

  /// The two-colour gradient a stable seed maps to, for an identity with no
  /// photo of its own.
  ///
  /// Derived from the live palette rather than hand-picked. The five variants
  /// used to be a `const` list of emerald greens copied into three files, so
  /// somebody on the indigo theme had a blue app full of green faces, and
  /// switching themes changed everything except the one thing standing in for
  /// a person. Same seed still lands on the same variant, so an identity's
  /// colour is as stable as it ever was — it just belongs to the theme now.
  static List<Color> identityGradient(String seed) {
    final a = brandPrimary;
    final b = brandSecondary;
    final variants = <List<Color>>[
      [a, b],
      [b, a],
      [a, Color.lerp(a, b, 0.55)!],
      [Color.lerp(b, a, 0.55)!, b],
      [Color.lerp(a, b, 0.25)!, Color.lerp(a, b, 0.9)!],
    ];
    return variants[seed.hashCode.abs() % variants.length];
  }
}
