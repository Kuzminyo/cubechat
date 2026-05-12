import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'colors.dart';

abstract final class AppTypography {
  static TextTheme build() {
    final base = GoogleFonts.interTextTheme();
    return base.copyWith(
      // Big screen titles use Space Grotesk (display).
      displayLarge: GoogleFonts.spaceGrotesk(
        color: AppColors.textPrimary,
        fontWeight: FontWeight.w700,
        fontSize: 34,
        letterSpacing: -0.8,
        height: 1.05,
      ),
      displayMedium: GoogleFonts.spaceGrotesk(
        color: AppColors.textPrimary,
        fontWeight: FontWeight.w600,
        fontSize: 28,
        letterSpacing: -0.5,
        height: 1.1,
      ),
      headlineMedium: GoogleFonts.spaceGrotesk(
        color: AppColors.textPrimary,
        fontWeight: FontWeight.w600,
        fontSize: 22,
        letterSpacing: -0.3,
      ),
      titleLarge: GoogleFonts.spaceGrotesk(
        color: AppColors.textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),

      // Body uses Inter (better at small sizes).
      titleMedium: base.titleMedium?.copyWith(
        color: AppColors.textPrimary,
        fontSize: 15,
        fontWeight: FontWeight.w500,
      ),
      bodyLarge: base.bodyLarge?.copyWith(
        color: AppColors.textPrimary,
        fontSize: 15,
      ),
      bodyMedium: base.bodyMedium?.copyWith(
        color: AppColors.textOnGlassDim,
        fontSize: 13,
      ),
      bodySmall: base.bodySmall?.copyWith(
        color: AppColors.textOnGlassFaint,
        fontSize: 11,
      ),
      labelLarge: base.labelLarge?.copyWith(
        color: AppColors.textPrimary,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  /// Big page-title style (Space Grotesk). Use this for the top of every screen.
  static TextStyle display({
    double size = 32,
    FontWeight weight = FontWeight.w700,
    Color? color,
  }) {
    return GoogleFonts.spaceGrotesk(
      fontSize: size,
      fontWeight: weight,
      color: color ?? AppColors.textPrimary,
      letterSpacing: -0.8,
      height: 1.05,
    );
  }

  /// Mid-weight heading (Space Grotesk). Use for sub-titles, peer names in chat header.
  static TextStyle heading({
    double size = 18,
    FontWeight weight = FontWeight.w600,
    Color? color,
  }) {
    return GoogleFonts.spaceGrotesk(
      fontSize: size,
      fontWeight: weight,
      color: color ?? AppColors.textPrimary,
      letterSpacing: -0.3,
    );
  }

  static TextStyle mono({
    double size = 12,
    FontWeight weight = FontWeight.w400,
    Color? color,
  }) {
    return GoogleFonts.jetBrainsMono(
      fontSize: size,
      fontWeight: weight,
      color: color ?? AppColors.textOnGlassDim,
    );
  }
}
