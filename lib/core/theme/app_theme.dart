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
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      hoverColor: AppColors.glassHover,
    );
  }
}
