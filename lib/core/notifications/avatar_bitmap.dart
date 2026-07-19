import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Renders a circular monogram avatar (deterministic gradient + initials) to
/// PNG bytes, so a system notification can show the same identity avatar the
/// chat UI does (`IdentityAvatar`). Runs headless via the dart:ui recorder —
/// no widget tree required — so it works from the background message path.
///
/// Returns null on any failure; the caller then just omits the icon.

const List<List<Color>> _palettes = [
  [Color(0xFF2EDB8F), Color(0xFF7FD9A6)],
  [Color(0xFF34D399), Color(0xFFA3E635)],
  [Color(0xFF7FD9A6), Color(0xFF2EDB8F)],
  [Color(0xFFA3E635), Color(0xFF34D399)],
  [Color(0xFF2EDB8F), Color(0xFFA3E635)],
];

Future<Uint8List?> renderAvatarPng({
  required String seed,
  required String label,
  int size = 128,
}) async {
  try {
    final s = size.toDouble();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final rect = Rect.fromLTWH(0, 0, s, s);

    final palette = _palettes[seed.hashCode.abs() % _palettes.length];
    final fill = Paint()
      ..isAntiAlias = true
      ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, palette);
    canvas.drawCircle(Offset(s / 2, s / 2), s / 2, fill);

    final tp = TextPainter(
      text: TextSpan(
        text: _initials(label),
        style: TextStyle(
          color: Colors.white,
          fontSize: s * 0.4,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((s - tp.width) / 2, (s - tp.height) / 2));

    final image = await recorder.endRecording().toImage(size, size);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}

String _initials(String text) {
  final parts = text.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty || parts.first.isEmpty) return '?';
  if (parts.length == 1) return parts.first.characters.first.toUpperCase();
  return (parts.first.characters.first + parts[1].characters.first)
      .toUpperCase();
}
