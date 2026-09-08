import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
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
  const PhotoEditPainter({
    required this.image,
    required this.edit,
    this.stickers = const <String, ui.Image>{},
  });

  final ui.Image image;
  final PhotoEdit edit;

  /// Decoded sticker artwork, by asset path.
  ///
  /// Handed in rather than fetched here, because decoding is asynchronous and
  /// painting is not. A layer whose picture has not arrived yet is skipped for
  /// that frame instead of drawing a placeholder that would then appear in an
  /// export taken during the gap.
  final Map<String, ui.Image> stickers;

  Size get sourceSize => Size(image.width.toDouble(), image.height.toDouble());

  /// The size the result is, after cropping and standing it up.
  Size get outputSize => edit.crop.outputSize(sourceSize);

  /// Draw into [canvas], filling exactly [outputSize] from the origin.
  void paint(ui.Canvas canvas) {
    final src = edit.crop.pixels(sourceSize);
    final out = outputSize;

    canvas.save();
    _orient(canvas, src, out);

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

    // Stickers and text go on *after* that layer is closed, which is what
    // makes "the eraser rubs out the drawing and nothing else" a fact about
    // the paint order rather than a rule some future tool has to remember.
    if (edit.layers.isNotEmpty) {
      canvas.save();
      canvas.translate(-src.left, -src.top);
      final shortSide = math.min(src.width, src.height);
      for (final layer in edit.layers) {
        _paintLayer(canvas, layer, shortSide);
      }
      canvas.restore();
    }

    canvas.restore();
  }

  /// Stand the picture up, about the middle of the output, so the rotation
  /// does not also move it off the canvas.
  ///
  /// Its own method because the selection frame has to land in exactly the
  /// same place as the layer it frames, and a second hand-written copy of this
  /// transform is a frame that drifts as soon as one of the two is touched.
  void _orient(ui.Canvas canvas, Rect src, Size out) {
    if (edit.crop.quarterTurns % 4 == 0 && !edit.crop.flipped) return;
    canvas.translate(out.width / 2, out.height / 2);
    if (edit.crop.flipped) canvas.scale(-1, 1);
    canvas.rotate(edit.crop.quarterTurns * math.pi / 2);
    // Back to the *unrotated* frame, which is what the crop rect is in.
    canvas.translate(-src.width / 2, -src.height / 2);
  }

  /// Outline the layer the finger is holding. **Preview only** — nothing calls
  /// this on the export path, which is why the frame cannot end up in a sent
  /// picture.
  ///
  /// [strokeWidth] is in image pixels; the caller divides its screen width by
  /// the preview scale so the line is the same thickness on a thumbnail and on
  /// a full-screen photo.
  void paintSelection(ui.Canvas canvas, PhotoLayer layer, double strokeWidth) {
    final src = edit.crop.pixels(sourceSize);
    final bounds = layerBounds(layer);
    canvas.save();
    _orient(canvas, src, outputSize);
    canvas.translate(-src.left, -src.top);
    canvas.translate(layer.center.dx, layer.center.dy);
    if (layer.rotation != 0) canvas.rotate(layer.rotation);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset.zero,
          width: bounds.width,
          height: bounds.height,
        ),
        Radius.circular(strokeWidth * 4),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.85),
    );
    canvas.restore();
  }

  static void _paintStroke(ui.Canvas canvas, Stroke stroke) {
    if (stroke.points.isEmpty) return;

    // A single tap is a dot, not nothing. Drawn as a filled circle because a
    // one-point path strokes to nothing at all and reads as the pen having
    // missed.
    if (stroke.points.length == 1) {
      canvas.drawCircle(
        stroke.points.first,
        stroke.width / 2,
        _strokePaint(stroke)..style = PaintingStyle.fill,
      );
      return;
    }

    final path = Path()..moveTo(stroke.points.first.dx, stroke.points.first.dy);
    for (var i = 1; i < stroke.points.length; i++) {
      path.lineTo(stroke.points[i].dx, stroke.points[i].dy);
    }

    if (stroke.kind == PenKind.neon) {
      // Two passes: a wide blurred halo in the colour, then a bright core.
      // One pass with a glow reads as a smudge; the core is what makes it
      // look like a light rather than like a soft pen.
      canvas.drawPath(
        path,
        _strokePaint(stroke)
          ..strokeWidth = stroke.width * 2.1
          ..color = stroke.color.withValues(alpha: 0.55)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke.width * 0.7),
      );
      canvas.drawPath(
        path,
        _strokePaint(stroke)
          ..strokeWidth = stroke.width * 0.55
          ..color = Color.lerp(stroke.color, const Color(0xFFFFFFFF), 0.75)!,
      );
      return;
    }

    canvas.drawPath(path, _strokePaint(stroke));

    if (stroke.kind == PenKind.arrow) {
      _paintArrowHead(canvas, stroke);
    }
  }

  static Paint _strokePaint(Stroke stroke) {
    final marker = stroke.kind == PenKind.marker;
    return Paint()
      ..color = stroke.erase
          ? const Color(0xFF000000)
          // A highlighter stains rather than covers. Translucency is applied
          // to the whole path in one draw, not per segment, so a slow hand
          // does not come out darker than a quick one.
          : (marker ? stroke.color.withValues(alpha: 0.42) : stroke.color)
      ..strokeWidth = marker ? stroke.width * 1.6 : stroke.width
      ..strokeCap = marker ? StrokeCap.square : StrokeCap.round
      ..strokeJoin = marker ? StrokeJoin.bevel : StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..blendMode = stroke.erase ? BlendMode.clear : BlendMode.srcOver
      ..isAntiAlias = true;
  }

  /// Two barbs at the last point of the line.
  ///
  /// The direction is taken from a point some way back along the path, not
  /// from the previous sample: the last two points of a finger lifting off are
  /// often a pixel apart in an arbitrary direction, and a head aimed by them
  /// points somewhere the line never went.
  static void _paintArrowHead(ui.Canvas canvas, Stroke stroke) {
    final points = stroke.points;
    final tip = points.last;
    final back = stroke.width * 4;
    var anchor = points.first;
    for (var i = points.length - 2; i >= 0; i--) {
      anchor = points[i];
      if ((tip - anchor).distance >= back) break;
    }
    final d = tip - anchor;
    if (d.distance < 0.01) return;
    final angle = math.atan2(d.dy, d.dx);
    final length = stroke.width * 3.6;
    const spread = 0.45; // radians off the shaft, either side

    final paint = _strokePaint(stroke);
    for (final side in <double>[-1, 1]) {
      final a = angle + math.pi + side * spread;
      canvas.drawLine(
        tip,
        tip + Offset(math.cos(a), math.sin(a)) * length,
        paint,
      );
    }
  }

  void _paintLayer(ui.Canvas canvas, PhotoLayer layer, double shortSide) {
    canvas.save();
    canvas.translate(layer.center.dx, layer.center.dy);
    if (layer.rotation != 0) canvas.rotate(layer.rotation);
    switch (layer) {
      case StickerLayer():
        final art = stickers[layer.asset];
        if (art != null) {
          final side = shortSide * StickerLayer.baseFraction * layer.scale;
          canvas.drawImageRect(
            art,
            Rect.fromLTWH(0, 0, art.width.toDouble(), art.height.toDouble()),
            Rect.fromCenter(center: Offset.zero, width: side, height: side),
            Paint()..filterQuality = FilterQuality.medium,
          );
        }
      case TextLayer():
        _paintText(canvas, layer, shortSide);
    }
    canvas.restore();
  }

  static void _paintText(ui.Canvas canvas, TextLayer layer, double shortSide) {
    if (layer.text.trim().isEmpty) return;
    final size = shortSide * TextLayer.baseFontFraction * layer.scale;
    final maxWidth = shortSide * 2.2;

    TextPainter build(TextStyle style) => TextPainter(
          text: TextSpan(text: layer.text, style: style),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: maxWidth);

    final base = TextStyle(
      fontSize: size,
      height: 1.15,
      fontWeight: FontWeight.w700,
      letterSpacing: size * 0.01,
    );

    switch (layer.style) {
      case TextStyleKind.plain:
        final tp = build(
          base.copyWith(
            color: layer.color,
            shadows: <Shadow>[
              Shadow(
                color: const Color(0xFF000000).withValues(alpha: 0.45),
                blurRadius: size * 0.22,
                offset: Offset(0, size * 0.04),
              ),
            ],
          ),
        );
        tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));

      case TextStyleKind.filled:
        final ink = layer.color.computeLuminance() > 0.55
            ? const Color(0xFF101014)
            : const Color(0xFFFFFFFF);
        final tp = build(base.copyWith(color: ink));
        final pad = size * 0.3;
        final slab = RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset.zero,
            width: tp.width + pad * 2,
            height: tp.height + pad,
          ),
          Radius.circular(size * 0.32),
        );
        canvas.drawRRect(slab, Paint()..color = layer.color);
        tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));

      case TextStyleKind.outlined:
        // Outline first, fill on top: the other order eats half the outline,
        // which shows up as letters that look thin at small sizes.
        final outline = build(
          base.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = size * 0.16
              ..strokeJoin = StrokeJoin.round
              ..color = layer.color
              ..isAntiAlias = true,
          ),
        );
        outline.paint(canvas, Offset(-outline.width / 2, -outline.height / 2));
        final fill = build(base.copyWith(color: const Color(0xFFFFFFFF)));
        fill.paint(canvas, Offset(-fill.width / 2, -fill.height / 2));
    }
  }

  /// The box a layer occupies on the picture, unrotated — what a tap has to
  /// land in for that layer to be the one it selects.
  Rect layerBounds(PhotoLayer layer) {
    final src = edit.crop.pixels(sourceSize);
    final shortSide = math.min(src.width, src.height);
    switch (layer) {
      case StickerLayer():
        final side = shortSide * StickerLayer.baseFraction * layer.scale;
        return Rect.fromCenter(
          center: layer.center,
          width: side,
          height: side,
        );
      case TextLayer():
        final size = shortSide * TextLayer.baseFontFraction * layer.scale;
        final tp = TextPainter(
          text: TextSpan(
            text: layer.text.isEmpty ? ' ' : layer.text,
            style: TextStyle(
              fontSize: size,
              height: 1.15,
              fontWeight: FontWeight.w700,
            ),
          ),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: shortSide * 2.2);
        // Padded, because a finger aiming at a thin line of text misses it far
        // more often than it hits something else by accident.
        return Rect.fromCenter(
          center: layer.center,
          width: tp.width + size * 0.6,
          height: tp.height + size * 0.6,
        );
    }
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

/// Decode a bundled asset — the sticker stills, in practice.
Future<ui.Image> decodeAssetImage(String path) async {
  final data = await rootBundle.load(path);
  return decodeForEditing(data.buffer.asUint8List());
}
