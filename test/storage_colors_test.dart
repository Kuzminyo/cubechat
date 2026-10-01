import 'package:cubechat/core/theme/colors.dart';
import 'package:cubechat/features/profile/data/storage_usage.dart';
import 'package:cubechat/features/profile/presentation/storage_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The storage screen's rows and ring were a rainbow — every category the
/// theme's colour rotated round the wheel — and on a violet theme that meant
/// pink, orange and green rows on a violet screen. Asked for "под тему".
void main() {
  test('every category is a shade of the theme, and no two are alike', () {
    final theme = HSLColor.fromColor(AppColors.brandPrimary).hue;
    final colours = [for (final c in StorageCategory.values) storageColor(c)];
    for (final colour in colours) {
      final hue = HSLColor.fromColor(colour).hue;
      final apart = ((hue - theme + 540) % 360) - 180;
      expect(apart.abs(), lessThanOrEqualTo(15), reason: '$colour');
    }
    expect(colours.toSet(), hasLength(colours.length));
  });

  test('neighbours on the ring stand apart in lightness', () {
    final values = StorageCategory.values;
    for (var i = 1; i < values.length; i++) {
      final a = HSLColor.fromColor(storageColor(values[i - 1])).lightness;
      final b = HSLColor.fromColor(storageColor(values[i])).lightness;
      expect((a - b).abs(), greaterThan(0.08),
          reason: '${values[i - 1]} and ${values[i]}');
    }
  });
}
