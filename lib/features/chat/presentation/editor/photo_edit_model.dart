import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// One freehand mark, in **image** coordinates.
///
/// Image coordinates rather than screen ones, and that is the whole reason
/// this type exists. A stroke recorded where the finger was on screen is
/// correct until the picture is cropped, rotated or the window resizes, and
/// then it is somewhere else — which is how a drawn arrow ends up pointing at
/// nothing. Recording against the picture means the mark travels with what it
/// was drawn on, and export needs no second transform.
@immutable
class Stroke {
  const Stroke({
    required this.points,
    required this.color,
    required this.width,
    this.erase = false,
  });

  final List<Offset> points;
  final Color color;

  /// In image pixels, so a mark keeps its thickness relative to the photo
  /// rather than to whatever screen it was drawn on.
  final double width;

  /// Erasers are strokes too: same points, same width, drawn with
  /// [BlendMode.clear] into the layer that holds the drawing. Modelling them
  /// as a separate list would make undo have to merge two histories.
  final bool erase;
}

/// Brightness, contrast and saturation, as the sliders set them.
///
/// Each is -1..1 with 0 meaning untouched, so "no adjustment" is the zero
/// value of every field and a reset is [PhotoAdjust.none].
@immutable
class PhotoAdjust {
  const PhotoAdjust({
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
  });

  static const none = PhotoAdjust();

  final double brightness;
  final double contrast;
  final double saturation;

  bool get isIdentity => brightness == 0 && contrast == 0 && saturation == 0;

  PhotoAdjust copyWith({
    double? brightness,
    double? contrast,
    double? saturation,
  }) =>
      PhotoAdjust(
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        saturation: saturation ?? this.saturation,
      );

  /// The 4x5 matrix `ColorFilter.matrix` wants, composed in one pass.
  ///
  /// Multiplied out by hand rather than by chaining three `ColorFilter`s:
  /// chaining is three full-screen passes per frame on the preview, and the
  /// same three on every exported pixel. The order is saturation, then
  /// contrast, then brightness — the order the sliders read in, so dragging
  /// one does what its name says regardless of where the others are.
  List<double> get matrix {
    // Saturation, on the usual luminance weights.
    final s = 1 + saturation;
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final sr = (1 - s) * lr, sg = (1 - s) * lg, sb = (1 - s) * lb;

    // Contrast about mid-grey, so raising it does not also brighten.
    final c = 1 + contrast;
    final ct = 128 * (1 - c);

    // Brightness as a plain offset, in 0..255 terms.
    final b = brightness * 96;

    double m(double v) => v * c;
    final t = ct + b;

    return <double>[
      m(sr + s), m(sg), m(sb), 0, t, //
      m(sr), m(sg + s), m(sb), 0, t,
      m(sr), m(sg), m(sb + s), 0, t,
      0, 0, 0, 1, 0,
    ];
  }
}

/// Where the picture is cut, and which way up.
///
/// [rect] is normalised 0..1 against the *unrotated* image, so it survives a
/// window resize and means the same thing on any screen. [quarterTurns] is
/// applied after the cut, which is the order a person expects: they frame the
/// picture and then stand it up.
@immutable
class PhotoCrop {
  const PhotoCrop({
    this.rect = const Rect.fromLTWH(0, 0, 1, 1),
    this.quarterTurns = 0,
    this.flipped = false,
  });

  static const none = PhotoCrop();

  final Rect rect;
  final int quarterTurns;
  final bool flipped;

  bool get isIdentity =>
      rect == const Rect.fromLTWH(0, 0, 1, 1) &&
      quarterTurns % 4 == 0 &&
      !flipped;

  PhotoCrop copyWith({Rect? rect, int? quarterTurns, bool? flipped}) =>
      PhotoCrop(
        rect: rect ?? this.rect,
        quarterTurns: quarterTurns ?? this.quarterTurns,
        flipped: flipped ?? this.flipped,
      );

  /// The pixel rectangle [rect] names inside an image of [size].
  ///
  /// Clamped and never empty: a rect dragged past an edge, or collapsed to a
  /// line by a fast pinch, would otherwise ask the compositor for a zero-sized
  /// surface — which throws rather than producing an empty picture.
  Rect pixels(Size size) {
    final l = (rect.left * size.width).clamp(0.0, size.width - 1);
    final t = (rect.top * size.height).clamp(0.0, size.height - 1);
    final r = (rect.right * size.width).clamp(l + 1, size.width);
    final b = (rect.bottom * size.height).clamp(t + 1, size.height);
    return Rect.fromLTRB(l, t, r, b);
  }

  /// The size the exported picture ends up, given the source [size].
  Size outputSize(Size size) {
    final p = pixels(size);
    return quarterTurns.isOdd
        ? Size(p.height, p.width)
        : Size(p.width, p.height);
  }
}

/// Everything an edit is, as one immutable value.
///
/// One value rather than three controllers, because undo has to move all of it
/// together: cropping and then drawing and then undoing twice must put the
/// crop back as well. A stack of these is the whole history — strokes are
/// shared by reference between snapshots, so a step costs a list header rather
/// than a copy of the drawing.
@immutable
class PhotoEdit {
  const PhotoEdit({
    this.strokes = const <Stroke>[],
    this.adjust = PhotoAdjust.none,
    this.crop = PhotoCrop.none,
  });

  final List<Stroke> strokes;
  final PhotoAdjust adjust;
  final PhotoCrop crop;

  bool get isUntouched =>
      strokes.isEmpty && adjust.isIdentity && crop.isIdentity;

  PhotoEdit copyWith({
    List<Stroke>? strokes,
    PhotoAdjust? adjust,
    PhotoCrop? crop,
  }) =>
      PhotoEdit(
        strokes: strokes ?? this.strokes,
        adjust: adjust ?? this.adjust,
        crop: crop ?? this.crop,
      );
}

/// The edit, plus the ability to take it back.
///
/// A snapshot stack rather than a list of inverse operations. Inverses are
/// smaller and are also where undo bugs live: every new tool has to know how
/// to undo itself, and the one that forgets is discovered by a user. A
/// snapshot cannot be wrong about what the picture was.
class PhotoEditHistory extends ChangeNotifier {
  final List<PhotoEdit> _past = <PhotoEdit>[];
  final List<PhotoEdit> _future = <PhotoEdit>[];
  PhotoEdit _now = const PhotoEdit();

  /// Deep enough for a drawing session, bounded because each snapshot pins the
  /// stroke list it was taken with.
  static const int _maxDepth = 60;

  PhotoEdit get value => _now;
  bool get canUndo => _past.isNotEmpty;
  bool get canRedo => _future.isNotEmpty;
  bool get isUntouched => _past.isEmpty && _now.isUntouched;

  /// Commit a new state, discarding any redo branch.
  void push(PhotoEdit next) {
    if (identical(next, _now)) return;
    _past.add(_now);
    if (_past.length > _maxDepth) _past.removeAt(0);
    _future.clear();
    _now = next;
    notifyListeners();
  }

  /// Change the current state *without* a history step.
  ///
  /// For a slider being dragged: one snapshot per frame would fill the stack
  /// with sixty versions of the same move, and undo would then take sixty taps
  /// to get back. The caller pushes once when the drag ends.
  void replace(PhotoEdit next) {
    _now = next;
    notifyListeners();
  }

  void undo() {
    if (_past.isEmpty) return;
    _future.add(_now);
    _now = _past.removeLast();
    notifyListeners();
  }

  void redo() {
    if (_future.isEmpty) return;
    _past.add(_now);
    _now = _future.removeLast();
    notifyListeners();
  }

  void reset() {
    if (_past.isEmpty && _now.isUntouched) return;
    _past.clear();
    _future.clear();
    _now = const PhotoEdit();
    notifyListeners();
  }
}

/// Map a point on the displayed picture back to where it is on the image.
///
/// The preview is letterboxed inside whatever space the screen has, so a touch
/// at the top-left of the widget is not the top-left of the photo. Getting
/// this wrong does not look like a bug in the drawing — it looks like the pen
/// lagging behind the finger by an amount that changes with the phone.
Offset toImageSpace(Offset local, Size widget, Size image) {
  if (image.isEmpty || widget.isEmpty) return Offset.zero;
  final scale = math.min(widget.width / image.width, widget.height / image.height);
  final drawn = Size(image.width * scale, image.height * scale);
  final dx = (widget.width - drawn.width) / 2;
  final dy = (widget.height - drawn.height) / 2;
  return Offset((local.dx - dx) / scale, (local.dy - dy) / scale);
}
