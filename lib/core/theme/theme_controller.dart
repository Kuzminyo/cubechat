import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../storage/hive_cipher.dart';
import '../storage/hive_init.dart';
import 'colors.dart';

/// One named look: the two brand colours and the three background tones.
///
/// A fixed set rather than a colour wheel. The whole interface is glass over a
/// drifting aurora, and those layers are tuned against each other — an
/// arbitrary hue picked from a wheel lands as unreadable text on a clashing
/// backdrop about as often as not. Each of these was chosen as a set.
@immutable
class AppPalette {
  const AppPalette({
    required this.id,
    required this.brandPrimary,
    required this.brandSecondary,
    required this.bgDeep,
    required this.bgTop,
    required this.bgBottom,
  });

  final String id;
  final Color brandPrimary;
  final Color brandSecondary;
  final Color bgDeep;
  final Color bgTop;
  final Color bgBottom;

  /// The original. Kept first and used as the fallback for an unknown id, so a
  /// palette removed in a later build cannot leave someone on a blank theme.
  static const emerald = AppPalette(
    id: 'emerald',
    brandPrimary: Color(0xFF2EDB8F),
    brandSecondary: Color(0xFF7FD9A6),
    bgDeep: Color(0xFF06140D),
    bgTop: Color(0xFF0D2818),
    bgBottom: Color(0xFF0A3D28),
  );

  static const indigo = AppPalette(
    id: 'indigo',
    brandPrimary: Color(0xFF7C8CFF),
    brandSecondary: Color(0xFFA9B4FF),
    bgDeep: Color(0xFF080A18),
    bgTop: Color(0xFF141A33),
    bgBottom: Color(0xFF1B2450),
  );

  static const amber = AppPalette(
    id: 'amber',
    brandPrimary: Color(0xFFF5A623),
    brandSecondary: Color(0xFFF7CE68),
    bgDeep: Color(0xFF150E05),
    bgTop: Color(0xFF2A1B08),
    bgBottom: Color(0xFF3D290C),
  );

  static const rose = AppPalette(
    id: 'rose',
    brandPrimary: Color(0xFFFF6B9D),
    brandSecondary: Color(0xFFFFA0BF),
    bgDeep: Color(0xFF160810),
    bgTop: Color(0xFF2B1220),
    bgBottom: Color(0xFF3F1A2E),
  );

  static const slate = AppPalette(
    id: 'slate',
    brandPrimary: Color(0xFF8FA3B8),
    brandSecondary: Color(0xFFB9C7D6),
    bgDeep: Color(0xFF0A0D10),
    bgTop: Color(0xFF161B20),
    bgBottom: Color(0xFF232B33),
  );

  static const all = <AppPalette>[emerald, indigo, amber, rose, slate];

  static AppPalette byId(String? id) =>
      all.firstWhere((p) => p.id == id, orElse: () => emerald);
}

/// Applies a palette and remembers the choice.
///
/// The colours are written into [AppColors]' static fields rather than handed
/// down through a `Theme`. Six hundred call sites read `AppColors.x` directly,
/// and threading an inherited widget through all of them would be a far larger
/// and riskier change than the feature is worth. The cost of the shortcut is
/// that widgets already built do not know their colours moved — which is why
/// applying a palette also bumps [revision], and the app is keyed on it so the
/// tree is rebuilt from scratch.
class ThemeController extends Notifier<AppPalette> {
  static const _key = 'app.palette';

  Box<dynamic>? _box;

  /// Incremented on every change. The only reader is the key on the app's root,
  /// which is what forces const-built widgets to be discarded and rebuilt.
  int revision = 0;

  @override
  AppPalette build() {
    unawaited(_load());
    _apply(AppPalette.emerald);
    return AppPalette.emerald;
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final saved = AppPalette.byId(box.get(_key) as String?);
      if (saved.id != state.id) select(saved);
    } catch (e) {
      debugPrint('ThemeController load failed: $e');
    }
  }

  Future<void> select(AppPalette palette) async {
    if (palette.id == state.id && revision != 0) return;
    _apply(palette);
    revision++;
    state = palette;
    try {
      await _box?.put(_key, palette.id);
    } catch (e) {
      debugPrint('ThemeController persist failed: $e');
    }
  }

  void _apply(AppPalette p) {
    AppColors.brandPrimary = p.brandPrimary;
    AppColors.brandSecondary = p.brandSecondary;
    AppColors.brandGradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [p.brandPrimary, p.brandSecondary],
    );
    AppColors.bgDeep = p.bgDeep;
    AppColors.bgTop = p.bgTop;
    AppColors.bgBottom = p.bgBottom;
    // The aurora blobs are the brand colours at different weights; leaving them
    // green under an indigo palette was the one thing that gave the shortcut
    // away.
    AppColors.aurora1 = p.brandPrimary;
    AppColors.aurora2 = p.brandSecondary;
    AppColors.aurora3 = p.brandPrimary;
    AppColors.aurora4 = p.brandSecondary;
    // "Online" is a status, not branding — but it has always been the brand
    // green, and a green dot on an amber interface reads as a different app.
    AppColors.online = p.brandPrimary;
  }

  /// Reset to the stock look — Emergency Wipe restores what a fresh install has.
  Future<void> reset() => select(AppPalette.emerald);
}

final themeControllerProvider = NotifierProvider<ThemeController, AppPalette>(
  ThemeController.new,
);
