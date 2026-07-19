import 'package:flutter/material.dart';

import 'colors.dart';
import 'typography.dart';

abstract final class AppTheme {
  static ThemeData dark() {
    final textTheme = AppTypography.build();
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.bgDeep,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.brandPrimary,
        brightness: Brightness.dark,
        primary: AppColors.brandPrimary,
        secondary: AppColors.brandSecondary,
        surface: AppColors.bgDeep,
        error: AppColors.danger,
      ),
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: AppColors.textOnGlass),
        titleTextStyle: textTheme.titleLarge,
      ),
      iconTheme: IconThemeData(color: AppColors.textOnGlass, size: 22),
      // Almost every confirmation in the app now goes through showGlassToast.
      // What is left here are the few SnackBars that carry an action button,
      // which a toast deliberately cannot (it is IgnorePointer). Without this
      // theme they arrived as light Material slabs over a dark glass
      // interface — the reason the toast pass happened at all — so the
      // stragglers get dressed properly rather than left to the default.
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.bgTop,
        contentTextStyle: TextStyle(color: AppColors.textOnGlass, fontSize: 14),
        actionTextColor: AppColors.brandPrimary,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
        ),
      ),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      hoverColor: AppColors.glassHover,
    );
  }
}
