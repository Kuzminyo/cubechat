import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cubechat/features/chat/presentation/editor/photo_edit_model.dart';
import 'package:cubechat/features/chat/presentation/editor/photo_edit_render.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// The editor that replaced `pro_image_editor`.
///
/// The parts worth pinning are the ones a screenshot cannot check: that the
/// colour matrix is composed rather than chained, that a crop rectangle can
/// never be empty, that a stroke recorded on screen lands where the finger was
/// on the *picture*, and that the export really produces the picture the
/// preview drew.
Future<Uint8List> _sourceJpeg({int w = 64, int h = 40}) async {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      // A gradient, so a flip or a rotation is detectable in the output rather
      // than being a uniform block that looks the same either way.
      image.setPixelRgb(x, y, (x * 255) ~/ w, (y * 255) ~/ h, 128);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image));
}

/// A flat colour, for the cases where the question is what one pixel became
/// rather than where the picture went.
Future<Uint8List> _solidJpeg(int r, int g, int b, {int w = 64, int h = 40}) async {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgb(x, y, r, g, b);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 100));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the adjustment matrix', () {
    test('untouched is the identity, and says so', () {
      expect(PhotoAdjust.none.isIdentity, isTrue);
      final m = PhotoAdjust.none.matrix;
      expect(m, hasLength(20));
      // Diagonal ones, no offsets: the filter can be skipped entirely.
      expect(m[0], closeTo(1, 1e-9));
      expect(m[6], closeTo(1, 1e-9));
      expect(m[12], closeTo(1, 1e-9));
      expect(m[4], closeTo(0, 1e-9));
    });

    test('full desaturation collapses a row to the luminance weights', () {
      final m = const PhotoAdjust(saturation: -1).matrix;
      expect(m[0], closeTo(0.2126, 1e-6));
      expect(m[1], closeTo(0.7152, 1e-6));
      expect(m[2], closeTo(0.0722, 1e-6));
    });

    test('contrast turns about mid-grey rather than about black', () {
      // The whole reason for the offset: without it, raising contrast also
      // raises brightness and the two sliders fight.
      final m = const PhotoAdjust(contrast: 1).matrix;
      expect(m[0], closeTo(2, 1e-9));
      expect(m[4], closeTo(-128, 1e-9), reason: '128 * (1 - 2)');
    });

    test('brightness is an offset and leaves the scale alone', () {
      final m = const PhotoAdjust(brightness: 0.5).matrix;
      expect(m[0], closeTo(1, 1e-9));
      expect(m[4], closeTo(48, 1e-9));
    });
  });

  group('the crop rectangle', () {
    const size = Size(100, 50);

    test('the whole picture is the identity', () {
      expect(PhotoCrop.none.isIdentity, isTrue);
      expect(PhotoCrop.none.pixels(size), const Rect.fromLTWH(0, 0, 100, 50));
    });

    test('it can never be empty, however it is dragged', () {
      // A rect collapsed by a fast pinch would otherwise ask the compositor
      // for a zero-sized surface, which throws rather than drawing nothing.
      const flat = PhotoCrop(rect: Rect.fromLTWH(0.5, 0.5, 0, 0));
      final p = flat.pixels(size);
      expect(p.width, greaterThan(0));
      expect(p.height, greaterThan(0));
    });

    test('it stays inside the picture when dragged past an edge', () {
      const over = PhotoCrop(rect: Rect.fromLTRB(-1, -1, 2, 2));
      final p = over.pixels(size);
      expect(p.left, greaterThanOrEqualTo(0));
      expect(p.top, greaterThanOrEqualTo(0));
      expect(p.right, lessThanOrEqualTo(size.width));
      expect(p.bottom, lessThanOrEqualTo(size.height));
    });

    test('a quarter turn swaps the output sides', () {
      expect(PhotoCrop.none.outputSize(size), size);
      expect(
        const PhotoCrop(quarterTurns: 1).outputSize(size),
        const Size(50, 100),
      );
      expect(
        const PhotoCrop(quarterTurns: 2).outputSize(size),
        size,
        reason: 'upside down is the same shape',
      );
    });
  });

  group('a touch becomes a point on the picture', () {
    // The preview is letterboxed, so the widget's origin is not the photo's.
    // Getting this wrong does not look like a bug in the drawing — it looks
    // like the pen lagging behind the finger by an amount that changes with
    // the phone.
    test('the middle of a letterboxed view is the middle of the image', () {
      const widget = Size(400, 400);
      const image = Size(200, 100); // wide: bars top and bottom
      expect(
        toImageSpace(const Offset(200, 200), widget, image),
        const Offset(100, 50),
      );
    });

    test('the top-left of the drawn area is the image origin', () {
      const widget = Size(400, 400);
      const image = Size(200, 100);
      // Scale 2, drawn height 200, so the picture starts 100 down.
      expect(
        toImageSpace(const Offset(0, 100), widget, image),
        const Offset(0, 0),
      );
    });

    test('an empty image cannot divide by zero', () {
      expect(toImageSpace(Offset.zero, const Size(10, 10), Size.zero),
          Offset.zero);
    });
  });

  group('history', () {
    test('an untouched edit reports itself as one', () {
      final h = PhotoEditHistory();
      addTearDown(h.dispose);
      expect(h.isUntouched, isTrue);
      expect(h.canUndo, isFalse);
    });

    test('undo puts back everything, not only the last tool', () {
      // A snapshot stack rather than inverse operations, because the tool that
      // forgets how to undo itself is discovered by a user.
      final h = PhotoEditHistory();
      addTearDown(h.dispose);
      h.push(const PhotoEdit(crop: PhotoCrop(quarterTurns: 1)));
      h.push(h.value.copyWith(adjust: const PhotoAdjust(contrast: 0.5)));
      expect(h.value.crop.quarterTurns, 1);
      h.undo();
      expect(h.value.adjust.isIdentity, isTrue);
      expect(h.value.crop.quarterTurns, 1, reason: 'the crop was a step back');
      h.undo();
      expect(h.value.isUntouched, isTrue);
    });

    test('a new step discards the redo branch', () {
      final h = PhotoEditHistory();
      addTearDown(h.dispose);
      h.push(const PhotoEdit(adjust: PhotoAdjust(contrast: 0.2)));
      h.undo();
      expect(h.canRedo, isTrue);
      h.push(const PhotoEdit(adjust: PhotoAdjust(contrast: 0.9)));
      expect(h.canRedo, isFalse);
    });

    test('replace does not add a step, which is what a slider needs', () {
      final h = PhotoEditHistory();
      addTearDown(h.dispose);
      for (var i = 0; i < 60; i++) {
        h.replace(PhotoEdit(adjust: PhotoAdjust(contrast: i / 60)));
      }
      expect(h.canUndo, isFalse,
          reason: 'sixty snapshots of one drag would take sixty taps to undo');
      h.push(h.value);
      expect(h.canUndo, isFalse, reason: 'pushing the same value is not a step');
    });
  });

  group('the export is the preview', () {
    testWidgets('an untouched picture round-trips at its own size',
        (tester) async {
      await tester.runAsync(() async {
        final image = await decodeForEditing(await _sourceJpeg());
        addTearDown(image.dispose);
        final painter =
            PhotoEditPainter(image: image, edit: const PhotoEdit());
        expect(painter.outputSize, const Size(64, 40));
        final bytes = await renderEdit(painter);
        final decoded = img.decodeJpg(bytes)!;
        expect(decoded.width, 64);
        expect(decoded.height, 40);
      });
    });

    testWidgets('a quarter turn comes out standing up', (tester) async {
      await tester.runAsync(() async {
        final image = await decodeForEditing(await _sourceJpeg());
        addTearDown(image.dispose);
        final bytes = await renderEdit(PhotoEditPainter(
          image: image,
          edit: const PhotoEdit(crop: PhotoCrop(quarterTurns: 1)),
        ));
        final decoded = img.decodeJpg(bytes)!;
        expect(decoded.width, 40);
        expect(decoded.height, 64);
      });
    });

    testWidgets('a crop comes out the size of the crop', (tester) async {
      await tester.runAsync(() async {
        final image = await decodeForEditing(await _sourceJpeg());
        addTearDown(image.dispose);
        final bytes = await renderEdit(PhotoEditPainter(
          image: image,
          edit: const PhotoEdit(
            crop: PhotoCrop(rect: Rect.fromLTWH(0.25, 0, 0.5, 1)),
          ),
        ));
        final decoded = img.decodeJpg(bytes)!;
        expect(decoded.width, 32);
        expect(decoded.height, 40);
      });
    });

    testWidgets('a stroke actually reaches the exported pixels',
        (tester) async {
      await tester.runAsync(() async {
        final image = await decodeForEditing(await _sourceJpeg());
        addTearDown(image.dispose);
        // A fat red line straight across the middle.
        final bytes = await renderEdit(PhotoEditPainter(
          image: image,
          edit: const PhotoEdit(strokes: <Stroke>[
            Stroke(
              points: <ui.Offset>[Offset(0, 20), Offset(64, 20)],
              color: Color(0xFFFF0000),
              width: 12,
            ),
          ]),
        ));
        final decoded = img.decodeJpg(bytes)!;
        final p = decoded.getPixel(32, 20);
        expect(p.r, greaterThan(180), reason: 'the line is red');
        expect(p.g, lessThan(90));
        expect(p.b, lessThan(90));
      });
    });

    testWidgets('a marker stains rather than covers', (tester) async {
      await tester.runAsync(() async {
        final image = await decodeForEditing(await _solidJpeg(255, 255, 255));
        addTearDown(image.dispose);
        final bytes = await renderEdit(PhotoEditPainter(
          image: image,
          edit: const PhotoEdit(
            strokes: <Stroke>[
              Stroke(
                points: <ui.Offset>[Offset(0, 20), Offset(64, 20)],
                color: Color(0xFFFF0000),
                width: 12,
                kind: PenKind.marker,
              ),
            ],
          ),
        ));
        final p = img.decodeJpg(bytes)!.getPixel(32, 20);
        // Red over white through a highlighter is pink: the green and blue
        // channels come down but do not go out. A marker that covered would
        // read the same as the pen, and the two tools would be one tool.
        expect(p.r, greaterThan(200));
        expect(p.g, greaterThan(110), reason: 'white still shows through');
        expect(p.g, lessThan(200), reason: 'but it is tinted');
      });
    });

    testWidgets('a sticker reaches the exported pixels', (tester) async {
      await tester.runAsync(() async {
        final image = await decodeForEditing(await _solidJpeg(255, 255, 255));
        addTearDown(image.dispose);
        final art = await decodeForEditing(await _solidJpeg(0, 0, 255, w: 8, h: 8));
        addTearDown(art.dispose);
        final bytes = await renderEdit(PhotoEditPainter(
          image: image,
          edit: const PhotoEdit(
            layers: <PhotoLayer>[
              StickerLayer(id: 1, center: Offset(32, 20), asset: 'blue'),
            ],
          ),
          stickers: <String, ui.Image>{'blue': art},
        ));
        final p = img.decodeJpg(bytes)!.getPixel(32, 20);
        expect(p.b, greaterThan(180));
        expect(p.r, lessThan(90));
      });
    });

    testWidgets('the blur pen smears the photograph itself', (tester) async {
      await tester.runAsync(() async {
        // A hard black/white edge down the middle. A blur is only visible
        // against contrast, so a flat colour would pass this test whether or
        // not anything happened.
        final source = img.Image(width: 64, height: 40);
        for (var y = 0; y < 40; y++) {
          for (var x = 0; x < 64; x++) {
            final v = x < 32 ? 0 : 255;
            source.setPixelRgb(x, y, v, v, v);
          }
        }
        final image = await decodeForEditing(
          Uint8List.fromList(img.encodeJpg(source, quality: 100)),
        );
        addTearDown(image.dispose);

        final bytes = await renderEdit(PhotoEditPainter(
          image: image,
          edit: const PhotoEdit(
            strokes: <Stroke>[
              Stroke(
                points: <ui.Offset>[Offset(32, 0), Offset(32, 40)],
                color: Color(0xFFFFFFFF),
                width: 24,
                kind: PenKind.blur,
              ),
            ],
          ),
        ));
        final decoded = img.decodeJpg(bytes)!;
        // Just inside the black half, under the stroke: white has bled in.
        expect(decoded.getPixel(28, 20).r, greaterThan(40),
            reason: 'the edge is smeared where the brush went');
        // Outside the stroke the picture is untouched, which is what makes it
        // a brush and not a filter.
        expect(decoded.getPixel(4, 20).r, lessThan(30));
        expect(decoded.getPixel(60, 20).r, greaterThan(225));
      });
    });

    testWidgets('the eraser rubs out the drawing and not a sticker',
        (tester) async {
      await tester.runAsync(() async {
        final image = await decodeForEditing(await _solidJpeg(255, 255, 255));
        addTearDown(image.dispose);
        final art = await decodeForEditing(await _solidJpeg(0, 0, 255, w: 8, h: 8));
        addTearDown(art.dispose);
        // A red line across the middle, a sticker on top of it, and then an
        // eraser over both. The paint order is what protects the sticker; a
        // check inside the eraser would be a rule the next tool forgets.
        final bytes = await renderEdit(PhotoEditPainter(
          image: image,
          edit: const PhotoEdit(
            strokes: <Stroke>[
              Stroke(
                points: <ui.Offset>[Offset(0, 20), Offset(64, 20)],
                color: Color(0xFFFF0000),
                width: 12,
              ),
              Stroke(
                points: <ui.Offset>[Offset(0, 20), Offset(64, 20)],
                color: Color(0xFF000000),
                width: 30,
                kind: PenKind.eraser,
              ),
            ],
            layers: <PhotoLayer>[
              StickerLayer(id: 1, center: Offset(32, 20), asset: 'blue'),
            ],
          ),
          stickers: <String, ui.Image>{'blue': art},
        ));
        final decoded = img.decodeJpg(bytes)!;
        expect(decoded.getPixel(32, 20).b, greaterThan(180),
            reason: 'the sticker survived');
        final wiped = decoded.getPixel(3, 20);
        expect(wiped.r, greaterThan(200));
        expect(wiped.g, greaterThan(200), reason: 'the red line is gone');
      });
    });
  });

  group('the frame is dragged on the picture that is shown', () {
    // The crop is stored against the original and dragged on the standing-up
    // preview. Getting the pair wrong does not throw — it turns the frame
    // ninety degrees away from the finger, which reads as the crop tool being
    // broken rather than as a missing transform.
    const r = Rect.fromLTRB(0.1, 0.2, 0.4, 0.6);

    for (final turns in <int>[0, 1, 2, 3]) {
      for (final flipped in <bool>[false, true]) {
        test('a round trip through the view is the identity '
            '(turns $turns, flipped $flipped)', () {
          final crop = PhotoCrop(quarterTurns: turns, flipped: flipped);
          final back = crop.fromViewRect(crop.toViewRect(r));
          expect(back.left, closeTo(r.left, 1e-9));
          expect(back.top, closeTo(r.top, 1e-9));
          expect(back.right, closeTo(r.right, 1e-9));
          expect(back.bottom, closeTo(r.bottom, 1e-9));
        });
      }
    }

    test('a quarter turn moves the frame to where the picture went', () {
      // The strip down the left of an upright picture is the strip across the
      // top once it is turned a quarter clockwise.
      const left = Rect.fromLTRB(0, 0, 0.25, 1);
      const crop = PhotoCrop(quarterTurns: 1);
      final view = crop.toViewRect(left);
      expect(view.left, closeTo(0, 1e-9));
      expect(view.top, closeTo(0, 1e-9));
      expect(view.right, closeTo(1, 1e-9));
      expect(view.bottom, closeTo(0.25, 1e-9));
    });
  });

  group('a touch on the preview lands on the original', () {
    const source = Size(100, 50);

    test('with a crop, the output origin is the corner of the cut', () {
      const crop = PhotoCrop(rect: Rect.fromLTWH(0.25, 0, 0.5, 1));
      expect(crop.outputToImage(Offset.zero, source), const Offset(25, 0));
      expect(
        crop.outputToImage(const Offset(50, 50), source),
        const Offset(75, 50),
      );
    });

    test('with a quarter turn, the output origin is the far corner', () {
      const crop = PhotoCrop(quarterTurns: 1);
      // Turning a landscape picture a quarter clockwise brings its
      // bottom-left corner to the top-left of the screen.
      final p = crop.outputToImage(Offset.zero, source);
      expect(p.dx, closeTo(0, 1e-9));
      expect(p.dy, closeTo(50, 1e-9));
    });

    test('a drag is turned but not moved', () {
      // A position goes through the crop offset; a delta must not, or a
      // sticker jumps by the crop on every frame of the drag.
      const crop = PhotoCrop(
        rect: Rect.fromLTWH(0.25, 0, 0.5, 1),
        quarterTurns: 1,
      );
      final d = crop.viewDeltaToImage(const Offset(10, 0), source);
      expect(d.dx, closeTo(0, 1e-9));
      expect(d.dy, closeTo(-10, 1e-9), reason: 'right on screen is up here');
    });

    test('untouched, a drag is itself', () {
      expect(
        PhotoCrop.none.viewDeltaToImage(const Offset(3, -7), source),
        const Offset(3, -7),
      );
    });
  });

  group('levelling', () {
    const source = Size(100, 50);

    test('untouched is level, and level is untouched', () {
      expect(PhotoCrop.none.tilt, 0);
      expect(const PhotoCrop(tilt: 0.05).isIdentity, isFalse,
          reason: 'a tilted picture is an edit, so the export must run');
      expect(PhotoCrop.none.coverScale(source), 1);
    });

    test('the picture grows enough to leave no empty corner', () {
      // A frame turned inside itself must still be covered: at 15 degrees on
      // a 2:1 crop that is a third of the picture's width again. Under this
      // number the corners come out black, which is the whole reason it
      // exists.
      const crop = PhotoCrop(tilt: PhotoCrop.maxTilt);
      final k = crop.coverScale(source);
      expect(k, greaterThan(1.3));
      final c = math.cos(PhotoCrop.maxTilt).abs();
      final s = math.sin(PhotoCrop.maxTilt).abs();
      expect(k * (100 * c + 50 * s) / 100, greaterThanOrEqualTo(1));
    });

    test('a touch still lands where the finger is', () {
      // The levelling turns about the frame's own centre, so the centre is the
      // one point it cannot move. Everything else is checked by the round
      // trip below.
      const crop = PhotoCrop(tilt: 0.2);
      final p = crop.outputToImage(const Offset(50, 25), source);
      expect(p.dx, closeTo(50, 1e-6));
      expect(p.dy, closeTo(25, 1e-6));
    });

    test('a drag is turned by the levelling too', () {
      // Dragging to the right on a picture levelled by 0.2 rad has to move a
      // sticker along the *picture*, not along the screen — otherwise it
      // slides off whatever it was put on as soon as the horizon is fixed.
      const crop = PhotoCrop(tilt: 0.2);
      final d = crop.viewDeltaToImage(const Offset(10, 0), source);
      expect(d.dy, lessThan(0), reason: 'the picture is turned under it');
      expect(d.distance, lessThan(10), reason: 'and scaled up, so a screen '
          'pixel is less than an image pixel');
    });
  });

  group('layers', () {
    const a = StickerLayer(id: 1, center: Offset.zero, asset: 'a');
    const b = TextLayer(
      id: 2,
      center: Offset.zero,
      text: 'hi',
      color: Color(0xFFFFFFFF),
    );

    test('a changed layer replaces itself and nothing else', () {
      const edit = PhotoEdit(layers: <PhotoLayer>[a, b]);
      final moved = a.moved(center: const Offset(5, 5));
      final next = edit.withLayer(moved);
      expect(next.layers, hasLength(2));
      expect(next.layers.first.center, const Offset(5, 5));
      expect(identical(next.layers.last, b), isTrue);
    });

    test('removal is by identity, so an index cannot shift under it', () {
      const edit = PhotoEdit(layers: <PhotoLayer>[a, b]);
      final next = edit.withoutLayer(1);
      expect(next.layers, hasLength(1));
      expect(next.layers.single.id, 2);
      expect(next.layerById(1), isNull);
    });

    test('a picture with only a sticker on it is not untouched', () {
      expect(const PhotoEdit(layers: <PhotoLayer>[a]).isUntouched, isFalse);
      expect(const PhotoEdit().isUntouched, isTrue);
    });
  });
}
