import 'dart:typed_data';

import 'package:cubechat/core/transport/mtu_budget.dart';
import 'package:cubechat/core/util/image_encode.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// A red square in the middle of a large, otherwise empty canvas — the shape a
/// picture saved out of another app usually arrives in.
Uint8List _shapeOnEmptyCanvas() {
  final canvas = img.Image(width: 900, height: 700, numChannels: 4);
  img.fillRect(
    canvas,
    x1: 300,
    y1: 200,
    x2: 599,
    y2: 499,
    color: img.ColorRgba8(220, 40, 40, 255),
  );
  return Uint8List.fromList(img.encodePng(canvas));
}

void main() {
  // `compute` needs a binding to spawn its isolate.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a sticker is trimmed, scaled and kept in PNG', () async {
    final png = await encodeStickerPng(_shapeOnEmptyCanvas());
    expect(png, isNotNull);

    // Small enough to cross the mesh at all — the whole reason this runs on
    // the way into the library rather than on every send.
    expect(png!.length, lessThanOrEqualTo(kMaxOutgoingImageBytes));

    final decoded = img.decodePng(png);
    expect(decoded, isNotNull);

    // Still PNG with an alpha channel: a sticker's shape is the pixels it does
    // not draw, and a JPEG re-encode would fill those with a white rectangle.
    expect(decoded!.numChannels, 4);

    // Trimmed to the drawn part: the 900x700 canvas is gone and what is left
    // is the square, not its surroundings.
    expect((decoded.width - decoded.height).abs(), lessThanOrEqualTo(2));
    expect(decoded.width, lessThanOrEqualTo(512));
  });

  test('a picture with no transparency survives unchanged in shape', () async {
    final opaque = img.Image(width: 400, height: 200);
    img.fill(opaque, color: img.ColorRgb8(10, 120, 200));
    final png =
        await encodeStickerPng(Uint8List.fromList(img.encodePng(opaque)));
    expect(png, isNotNull);
    final decoded = img.decodePng(png!);
    // Nothing to trim, nothing to scale — 400 is already under the first rung.
    expect(decoded!.width, 400);
    expect(decoded.height, 200);
  });
}
