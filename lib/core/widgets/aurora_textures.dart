import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// The aurora's gradients, computed here as small images instead of handed to
/// the engine as gradient shaders.
///
/// Because the engine dithers every gradient it draws, and the aurora is the
/// one gradient that fills the screen. The dither is an ordered pattern a
/// level up and a level down every other pixel: invisible on the phone, and a
/// grid of white dots on every screenshot, since a screenshot is scaled down
/// before anyone looks at it and a two-pixel pattern folds into a coarse grid
/// when it is (11.6 px at 591/1080 on the reported one — exactly where it
/// lands). An image is sampled, not dithered, so the pattern is never drawn.
///
/// What it costs: nothing per frame — a texture covers the same pixels the
/// shader did — and a few milliseconds once per palette, off the frame.
/// Without the dither a dark gradient can show a faint step where the colour
/// moves one level; on this backdrop that is a step of one level in green
/// every ~170 px of the diagonal.
class AuroraTextures extends ChangeNotifier {
  AuroraTextures._();

  static final AuroraTextures instance = AuroraTextures._();

  /// Side of a blob's texture. Upscaled with bilinear filtering to a blob of
  /// ~600 px radius, so a texel is ~5 px: far finer than the falloff.
  static const int blobSide = 256;

  /// The base gradient's texture. A linear gradient is linear, so bilinear
  /// filtering reproduces it exactly between texel centres; the size only has
  /// to be large enough that the half texel clamped at each edge is nothing.
  static const int baseWidth = 32;
  static const int baseHeight = 64;

  final Map<Object, ui.Image> _ready = {};
  final Set<Object> _making = {};

  /// The blob of [color] at [alpha], or null until it is made — the caller
  /// draws its old gradient for that frame and is repainted when it arrives.
  ui.Image? blob(ui.Color color, double alpha) {
    final key = ('blob', color.toARGB32(), alpha);
    return _get(key, () => blobPixels(color, alpha, blobSide), blobSide,
        blobSide);
  }

  /// The diagonal base gradient for a screen of [size].
  ui.Image? base(ui.Color top, ui.Color bottom, ui.Size size) {
    final key = ('base', top.toARGB32(), bottom.toARGB32(), size);
    return _get(
      key,
      () => basePixels(top, bottom, size, baseWidth, baseHeight),
      baseWidth,
      baseHeight,
    );
  }

  ui.Image? _get(
    Object key,
    Uint8List Function() pixels,
    int width,
    int height,
  ) {
    final image = _ready[key];
    if (image != null) return image;
    if (_making.add(key)) {
      ui.decodeImageFromPixels(
        pixels(),
        width,
        height,
        ui.PixelFormat.rgba8888,
        (image) {
          _making.remove(key);
          _ready[key] = image;
          // A palette switch leaves the old palette's images unused; a
          // handful of small textures is not worth an eviction policy beyond
          // keeping the count bounded.
          if (_ready.length > 24) {
            final stale = _ready.keys.first;
            _ready.remove(stale)?.dispose();
          }
          notifyListeners();
        },
      );
    }
    return null;
  }

  /// A radial falloff from [color] at [alpha] in the centre to transparent at
  /// the edge, premultiplied, the way a two-stop `RadialGradient` interpolates
  /// it: colour and alpha each run linearly to zero.
  @visibleForTesting
  static Uint8List blobPixels(ui.Color color, double alpha, int side) {
    final out = Uint8List(side * side * 4);
    final half = side / 2;
    for (var y = 0; y < side; y++) {
      for (var x = 0; x < side; x++) {
        final dx = x + 0.5 - half;
        final dy = y + 0.5 - half;
        final t = math.min(1.0, math.sqrt(dx * dx + dy * dy) / half);
        final k = 1 - t;
        final a = alpha * k;
        final i = (y * side + x) * 4;
        out[i] = _byte(color.r * k * a);
        out[i + 1] = _byte(color.g * k * a);
        out[i + 2] = _byte(color.b * k * a);
        out[i + 3] = _byte(a);
      }
    }
    return out;
  }

  /// The top-left to bottom-right gradient across a screen of [size],
  /// sampled at the centre of each texel of a [w] by [h] image stretched over
  /// that screen — so the image reproduces the gradient's geometry, diagonal
  /// included, whatever the screen's proportions.
  @visibleForTesting
  static Uint8List basePixels(
    ui.Color top,
    ui.Color bottom,
    ui.Size size,
    int w,
    int h,
  ) {
    final out = Uint8List(w * h * 4);
    final sw = size.width;
    final sh = size.height;
    final len2 = sw * sw + sh * sh;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final px = (x + 0.5) / w * sw;
        final py = (y + 0.5) / h * sh;
        final t =
            len2 == 0 ? 0.0 : ((px * sw + py * sh) / len2).clamp(0.0, 1.0);
        final i = (y * w + x) * 4;
        out[i] = _byte(top.r + (bottom.r - top.r) * t);
        out[i + 1] = _byte(top.g + (bottom.g - top.g) * t);
        out[i + 2] = _byte(top.b + (bottom.b - top.b) * t);
        out[i + 3] = 255;
      }
    }
    return out;
  }

  static int _byte(double v) => (v * 255).round().clamp(0, 255);
}
