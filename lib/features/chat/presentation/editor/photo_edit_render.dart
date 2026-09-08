import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import 'photo_edit_model.dart';

/// Paints an edited picture onto a canvas.
///
/// **One painter for the preview and for the export**, which is the point.
/// Two code paths that both "draw the photo with the marks on it" drift, and
/// the drift is only ever discovered after something has been sent — the
/// preview is what the person approved, so it has to be the thing that is
/// encoded. The export calls this with a canvas backed by a picture recorder
/// instead of a screen, and nothing else differs.
class PhotoEditPainter {
  const PhotoEditPainter({required this.image, required this.edit});

  final ui.Image image;
  final PhotoEdit edit;

  Size get sourceSize =>
      Size(image.width.toDouble(), image.height.toDouble());

  /// The size the result is, after cropping and standing it up.
  Size get outputSize => edit.crop.outputSize(sourceSize);

  /// Draw into [canvas], filling exactly [outputSize] from the origin.
  void paint(ui.Canvas canvas) {
    final src = edit.crop.pixels(sourceSize);
    final out = outputSize;

    canvas.save();
    // Stand the picture up first, about the middle of the output, so the
    // rotation does not also move it off the canvas.
    if (edit.crop.quarterTurns % 4 != 0 || edit.crop.flipped) {
      canvas.translate(out.width / 2, out.height / 2);
      if (edit.crop.flipped) canvas.scale(-1, 1);
      canvas.rotate(edit.crop.quarterTurns * math.pi / 2);
      // Back to the *unrotated* frame, which is what the crop rect is in.
      canvas.translate(-src.width / 2, -src.height / 2);
    }

    // The adjustment rides on the paint rather than on a saveLayer: a filter
    // applied to the photo alone is what the sliders mean. Putting it on a
    // layer would tint the drawing too, so a red pen would fade when the
    // saturation slider came down.
    final photo = Paint();
    if (!edit.adjust.isIdentity) {
      photo.colorFilter = ColorFilter.matrix(edit.adjust.matrix);
    }
    canvas.drawImageRect(
      image,
      src,
      Rect.fromLTWH(0, 0, src.width, src.height),
      photo,
    );

    // The drawing goes in its own layer, because an eraser has to clear the
    // marks and not the photograph under them. BlendMode.clear against the
    // page would punch a hole through to nothing.
    if (edit.strokes.isNotEmpty) {
      canvas.saveLayer(Rect.fromLTWH(0, 0, src.width, src.height), Paint());
      canvas.translate(-src.left, -src.top);
      for (final stroke in edit.strokes) {
        _paintStroke(canvas, stroke);
      }
      canvas.restore();
    }

    canvas.restore();
  }

  static void _paintStroke(ui.Canvas canvas, Stroke stroke) {
    if (stroke.points.isEmpty) return;
    final paint = Paint()
      ..color = stroke.erase ? const Color(0xFF000000) : stroke.color
      ..strokeWidth = stroke.width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..blendMode = stroke.erase ? BlendMode.clear : BlendMode.srcOver
      ..isAntiAlias = true;

    // A single tap is a dot, not nothing. Drawn as a filled circle because a
    // one-point path strokes to nothing at all and reads as the pen having
    // missed.
    if (stroke.points.length == 1) {
      canvas.drawCircle(
        stroke.points.first,
        stroke.width / 2,
        paint..style = PaintingStyle.fill,
      );
      return;
    }

    final path = Path()..moveTo(stroke.points.first.dx, stroke.points.first.dy);
    for (var i = 1; i < stroke.points.length; i++) {
      path.lineTo(stroke.points[i].dx, stroke.points[i].dy);
    }
    canvas.drawPath(path, paint);
  }
}

/// Render the edit to JPEG bytes.
///
/// JPEG at 92 rather than PNG: everything downstream of here re-encodes a
/// photograph anyway (the mesh budget, the gallery path), and a PNG of a
/// camera picture is several times the size for no visible gain. The encoder
/// is the `image` package, already a dependency for exactly this reason.
Future<Uint8List> renderEdit(PhotoEditPainter painter) async {
  final out = painter.outputSize;
  final recorder = ui.PictureRecorder();
  painter.paint(ui.Canvas(recorder));
  final picture = recorder.endRecording();
  final raster = await picture.toImage(
    out.width.round().clamp(1, 1 << 15),
    out.height.round().clamp(1, 1 << 15),
  );
  picture.dispose();
  try {
    // Raw RGBA rather than PNG: `toByteData` can hand back either, and asking
    // for PNG here means encoding a lossless image only to throw it away in
    // the JPEG encode below.
    final data = await raster.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      throw StateError('the edited picture produced no pixels');
    }
    final frame = img.Image.fromBytes(
      width: raster.width,
      height: raster.height,
      bytes: data.buffer,
      numChannels: 4,
    );
    return img.encodeJpg(frame, quality: 92);
  } finally {
    raster.dispose();
  }
}

/// Decode bytes into something the painter can draw.
Future<ui.Image> decodeForEditing(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}
