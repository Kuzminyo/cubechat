import 'package:flutter/material.dart';

import 'colors.dart';

abstract final class AppTypography {
  static TextTheme build() {
    // Bundled Cyrillic + Latin: no network request or late font/layout swap.
    final base = Typography.material2021().white.apply(
          fontFamily: 'Inter',
          bodyColor: AppColors.textOnGlass,
          displayColor: AppColors.textPrimary,
        );
    return base.copyWith(
      // Big screen titles use Space Grotesk (display).
      // **Every weight here is one step lighter than it was.** The scale was
      // set while the text was still being drawn by google_fonts; bundling the
      // families changed what actually rasterises, and the same nominal weight
      // came out heavier on the phone than it had. Reported as the interface
      // looking too bold. Lighter is also the safer direction on a dark
      // background, where a stroke blooms against the glass rather than sitting
      // on it.
      displayLarge: TextStyle(
        fontFamily: 'SpaceGrotesk',
        fontFamilyFallback: const ['Inter'],
        color: AppColors.textPrimary,
        fontWeight: FontWeight.w600,
        fontSize: 34,
        letterSpacing: -0.8,
        height: 1.05,
      ),
      displayMedium: TextStyle(
        fontFamily: 'SpaceGrotesk',
        fontFamilyFallback: const ['Inter'],
        color: AppColors.textPrimary,
        fontWeight: FontWeight.w500,
        fontSize: 28,
        letterSpacing: -0.5,
        height: 1.1,
      ),
      headlineMedium: heading(size: 22),
      titleLarge: heading(),

      // Body uses Inter (better at small sizes).
      titleMedium: base.titleMedium?.copyWith(
        color: AppColors.textPrimary,
        fontSize: 15,
        fontWeight: FontWeight.w400,
      ),
      bodyLarge: base.bodyLarge?.copyWith(
        color: AppColors.textPrimary,
        fontSize: 15,
      ),
      bodyMedium: base.bodyMedium?.copyWith(
        color: AppColors.textOnGlassDim,
        fontSize: 14,
        height: 1.4,
      ),
      bodySmall: base.bodySmall?.copyWith(
        color: AppColors.textOnGlassFaint,
        fontSize: 12,
        height: 1.35,
      ),
      labelLarge: base.labelLarge?.copyWith(
        color: AppColors.textPrimary,
        fontSize: 14,
        fontWeight: FontWeight.w400,
      ),
    );
  }

  /// Big page-title style (Space Grotesk). Use this for the top of every screen.
  static TextStyle display({
    double size = 28,
    FontWeight weight = FontWeight.w600,
    Color? color,
  }) {
    return TextStyle(
      fontFamily: 'SpaceGrotesk',
      fontFamilyFallback: const ['Inter'],
      fontSize: size,
      fontWeight: weight,
      color: color ?? AppColors.textPrimary,
      letterSpacing: -0.8,
      height: 1.05,
    );
  }

  /// UI headings share the body family, including Cyrillic names.
  static TextStyle heading({
    double size = 18,
    FontWeight weight = FontWeight.w500,
    Color? color,
  }) {
    return TextStyle(
      fontFamily: 'Inter',
      fontSize: size,
      fontWeight: weight,
      color: color ?? AppColors.textPrimary,
      letterSpacing: -0.2,
      height: 1.25,
    );
  }

  /// Shared roles keep lists, settings and sheets on the same scale.
  static TextStyle get rowTitle => TextStyle(
        fontFamily: 'Inter',
        fontSize: 16,
        height: 1.3,
        fontWeight: FontWeight.w500,
        color: AppColors.textOnGlass,
      );
  static TextStyle get control => TextStyle(
        fontFamily: 'Inter',
        fontSize: 14,
        height: 1.25,
        fontWeight: FontWeight.w500,
        color: AppColors.textOnGlass,
      );
  static TextStyle get supporting => TextStyle(
        fontFamily: 'Inter',
        fontSize: 13,
        height: 1.4,
        color: AppColors.textOnGlassDim,
      );
  static TextStyle get caption => TextStyle(
        fontFamily: 'Inter',
        fontSize: 12,
        height: 1.3,
        color: AppColors.textOnGlassDim,
      );

  /// Fingerprints, contact ids — anything read character by character.
  ///
  /// The bundled Medium is deliberate. Previously a request for Regular
  /// missed the google_fonts asset match and made a network request to render
  /// a fingerprint. All three families are now registered directly in pubspec;
  /// no text role depends on a download or a late fallback-font swap.
  static TextStyle mono({
    double size = 12,
    FontWeight weight = FontWeight.w500,
    Color? color,
  }) {
    return TextStyle(
      fontFamily: 'JetBrainsMono',
      fontFamilyFallback: const ['Inter'],
      fontSize: size,
      fontWeight: weight,
      color: color ?? AppColors.textOnGlassDim,
    );
  }
}

/// One scale for every overflow menu in the app.
///
/// The same idea — three dots, a list of things you can do — was drawn at three
/// different scales: the shared popup at an 18-point icon over a 14-point
/// label, the contact panel at 24 over 16, and the buttons that open them at 22
/// and 25. Nothing was wrong with any single number; what read as unfinished
/// was that they disagreed, screen to screen, about how big a menu is.
///
/// Tokens rather than literals for the reason every design system gives: the
/// next menu added will reach for a name, and a name cannot drift the way a
/// number copied from a neighbouring file does.
abstract final class AppMenu {
  /// The glyph beside a row.
  static const double rowIcon = 18;

  /// The row's label.
  static const double rowLabel = 14;

  /// The line under it, when a row explains itself.
  static const double rowSubtitle = 11;

  /// The three dots themselves, and any other control that opens a menu.
  static const double buttonIcon = 22;

  /// A panel or sheet's own title, matched to the app bar's.
  static const double title = 18;
}
