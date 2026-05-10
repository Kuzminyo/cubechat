import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'colors.dart';

abstract final class AppTypography {
  static TextTheme build() {
    final base = GoogleFonts.interTextTheme();
    return base.copyWith(
      displayLarge: base.displayLarge?.copyWith(
        color: AppColors.textPrimary,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.02,
      ),
      headlineMedium: base.headlineMedium?.copyWith(
        color: AppColors.textPrimary,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.02,
      ),
      titleLarge: base.titleLarge?.copyWith(
        color: AppColors.textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
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

  static TextStyle mono({double size = 12, FontWeight weight = FontWeight.w400, Color? color}) {
    return GoogleFonts.jetBrainsMono(
      fontSize: size,
      fontWeight: weight,
      color: color ?? AppColors.textOnGlassDim,
    );
  }
}
