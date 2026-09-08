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
  });
}
