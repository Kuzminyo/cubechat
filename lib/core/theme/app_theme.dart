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
          side: BorderSide(color: AppColors.glass(0.16)),
        ),
      ),
      // No ripple, and that stays: a spreading circle over a pane of glass
      // reads as a smear, which is why it was turned off.
      splashFactory: NoSplash.splashFactory,
      // But a press has to be answered by *something*, immediately. With the
      // highlight transparent as well, nothing at all happened between the
      // finger landing and whatever the tap eventually did — so every control
      // in the app felt like it was thinking about it, and a tap that opened a
      // screen felt slower than the screen took. This is the acknowledgement:
      // a faint lift under the finger, no travel, nothing to spread.
      highlightColor: AppColors.glass(0.10),
      hoverColor: AppColors.glassHover,
    );
  }
}
