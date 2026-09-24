// Draws the launcher icon of every non-default palette, for both platforms:
//
//   android/app/src/main/res/drawable-*/ic_launcher_foreground_<id>.png
//       adaptive-icon foreground, Android 8+ (mipmap-anydpi-v26/ic_launcher_<id>.xml
//       puts it on @color/ic_launcher_background_<id>)
//   android/app/src/main/res/mipmap-*/ic_launcher_<id>.png
//       the full-bleed legacy icon, Android 7
//   ios/Runner/Assets.xcassets/AppIcon<Id>.appiconset/*.png
//       every file its Contents.json lists, opaque (App Store rejects alpha)
//
// Usage — a test only because that is the cheapest way to a rasteriser without
// a window, and kept under tool/ so the suite does not run it:
//
//   flutter test tool/export_theme_icons.dart
//
// Same painter and the same two treatments as the default icon, which
// tool/export_logo.dart + flutter_launcher_icons make from Emerald: glow off on
// a transparent layer for the adaptive foreground, glow on over the palette's
// bgDeep for everything opaque. So each icon matches the in-app CubeLogo drawn
// under the same palette.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cubechat/core/theme/theme_controller.dart';
import 'package:cubechat/core/widgets/cube_logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

const _res = 'android/app/src/main/res';

/// A 108dp adaptive layer, and a 48dp legacy icon, per density.
const _foregroundPx = <String, int>{
  'mdpi': 108,
  'hdpi': 162,
  'xhdpi': 216,
  'xxhdpi': 324,
  'xxxhdpi': 432,
};
const _legacyPx = <String, int>{
  'mdpi': 48,
  'hdpi': 72,
  'xhdpi': 96,
  'xxhdpi': 144,
  'xxxhdpi': 192,
};

Future<Uint8List> _draw(
  AppPalette palette,
  int side, {
  required bool opaque,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final size = Size(side.toDouble(), side.toDouble());
  if (opaque) {
    canvas.drawRect(Offset.zero & size, Paint()..color = palette.bgDeep);
  }
  CubeLogoPainter(
    glow: opaque,
    primary: palette.brandPrimary,
    secondary: palette.brandSecondary,
  ).paint(canvas, size);
  final image = await recorder.endRecording().toImage(side, side);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final png = data!.buffer.asUint8List();
  if (!opaque) return png;
  final decoded = img.decodePng(png)!;
  return img.encodePng(decoded.convert(numChannels: 3));
}

void main() {
  test('export per-theme launcher icons', () async {
    for (final palette in AppPalette.all) {
      if (palette.id == AppPalette.emerald.id) continue;
      final id = palette.id;

      for (final d in _foregroundPx.entries) {
        await File('$_res/drawable-${d.key}/ic_launcher_foreground_$id.png')
            .writeAsBytes(await _draw(palette, d.value, opaque: false));
      }
      for (final d in _legacyPx.entries) {
        await File('$_res/mipmap-${d.key}/ic_launcher_$id.png')
            .writeAsBytes(await _draw(palette, d.value, opaque: true));
      }

      final set = 'ios/Runner/Assets.xcassets/'
          'AppIcon${id[0].toUpperCase()}${id.substring(1)}.appiconset';
      final contents = jsonDecode(
        File('$set/Contents.json').readAsStringSync(),
      ) as Map<String, Object?>;
      for (final entry in (contents['images']! as List<Object?>)
          .cast<Map<String, Object?>>()) {
        final points = double.parse((entry['size']! as String).split('x')[0]);
        final scale = int.parse((entry['scale']! as String).replaceAll('x', ''));
        await File('$set/${entry['filename']}').writeAsBytes(
          await _draw(palette, (points * scale).round(), opaque: true),
        );
      }
    }
  });
}
