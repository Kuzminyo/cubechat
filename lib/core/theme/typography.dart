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
      ).copyWith(fontFamilyFallback: _emojiFallback),
      displayMedium: GoogleFonts.spaceGrotesk(
        color: AppColors.textPrimary,
        fontWeight: FontWeight.w600,
        fontSize: 28,
        letterSpacing: -0.5,
        height: 1.1,
      ).copyWith(fontFamilyFallback: _emojiFallback),
      headlineMedium: GoogleFonts.spaceGrotesk(
        color: AppColors.textPrimary,
        fontWeight: FontWeight.w600,
        fontSize: 22,
        letterSpacing: -0.3,
      ).copyWith(fontFamilyFallback: _emojiFallback),
      titleLarge: GoogleFonts.spaceGrotesk(
        color: AppColors.textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ).copyWith(fontFamilyFallback: _emojiFallback),

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
  /// Bundled Noto Color Emoji, behind every family this app uses.
  ///
  /// Emoji are not in Space Grotesk or JetBrains Mono, so without a stated
  /// fallback each phone reaches for whatever its vendor shipped — and a
  /// reaction picked on a Xiaomi arrives on a Samsung looking like a different
  /// feeling. Naming the fallback is what makes both ends of a conversation
  /// draw the same picture.
  static const List<String> _emojiFallback = <String>['NotoColorEmoji'];

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
    ).copyWith(fontFamilyFallback: _emojiFallback);
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
    ).copyWith(fontFamilyFallback: _emojiFallback);
  }

  /// Fingerprints, contact ids — anything read character by character.
  ///
  /// w500, not w400, because `.codex/fonts` bundles JetBrainsMono-**Medium**
  /// and google_fonts matches an asset by exact weight. Asking for Regular
  /// found nothing locally and fell through to a download from
  /// fonts.gstatic.com — on an app whose whole point is working with no
  /// internet, so the mesh-only case silently got the system font instead, and
  /// the online case made a request to Google to render a key fingerprint.
  /// The other two families already line up this way: display is w700 against
  /// SpaceGrotesk-Bold, heading w600 against SpaceGrotesk-SemiBold.
  static TextStyle mono({
    double size = 12,
    FontWeight weight = FontWeight.w500,
    Color? color,
  }) {
    return GoogleFonts.jetBrainsMono(
      fontSize: size,
      fontWeight: weight,
      color: color ?? AppColors.textOnGlassDim,
    ).copyWith(fontFamilyFallback: _emojiFallback);
  }
}
