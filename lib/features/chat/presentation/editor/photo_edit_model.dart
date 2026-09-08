import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// What the pen is, when it touches the picture.
///
/// A pen kind rather than a set of independent flags, because the kinds are
/// mutually exclusive by nature — a stroke is a marker or it is a neon line,
/// and a boolean per property would let both be true. The painter switches on
/// this one value, so a new kind is a case there and nothing else.
enum PenKind {
  /// An opaque round line. The default, and what most marks are.
  pen,

  /// Translucent and flat-capped, the way a highlighter behaves: it stains
  /// what is under it instead of covering it.
  marker,

  /// A coloured glow with a bright core, for marking a dark photograph where
  /// a flat line disappears into the picture.
  neon,

  /// A freehand line that ends in a head. Freehand rather than straight
  /// because an arrow drawn round an obstacle is the common case — pointing
  /// at a face in a crowd, not at the middle of an empty wall.
  arrow,

  /// Clears the drawing layer. Not the photograph, and not the stickers or
  /// text — those are painted above it, which is what makes that true by
  /// construction rather than by a check.
  eraser,
}

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
    this.kind = PenKind.pen,
  });

  final List<Offset> points;
  final Color color;

  /// In image pixels, so a mark keeps its thickness relative to the photo
  /// rather than to whatever screen it was drawn on.
  final double width;

  final PenKind kind;

  /// Erasers are strokes too: same points, same width, drawn with
  /// [BlendMode.clear] into the layer that holds the drawing. Modelling them
  /// as a separate list would make undo have to merge two histories.
  bool get erase => kind == PenKind.eraser;
}

/// How a piece of text is set on the picture.
enum TextStyleKind {
  /// Coloured letters with a shadow under them. Reads on most photographs and
  /// adds nothing to the picture.
  plain,

  /// The letters knocked out of a rounded slab of colour. For a caption that
  /// has to be read over a busy background.
  filled,

  /// The letters outlined in their colour and filled with white — legible on
  /// a dark and a bright picture at once, which neither of the others is.
  outlined,
}

/// Something placed on the picture that is not a pen mark: text, or a sticker.
///
/// Positioned in image coordinates for the same reason strokes are, and
/// carrying its own scale and rotation so that a pinch is one value change
/// rather than a rewritten geometry.
@immutable
sealed class PhotoLayer {
  const PhotoLayer({
    required this.id,
    required this.center,
    this.scale = 1,
    this.rotation = 0,
  });

  /// Identity that survives a copy, so the selection is not lost when the
  /// layer is moved — an index would shift the moment anything is deleted.
  final int id;

  final Offset center;

  /// Multiplies the layer's own base size, which is expressed in image
  /// pixels. Keeping the base in image pixels is what makes a sticker take up
  /// the same share of a 12 MP photo as of a screenshot.
  final double scale;

  /// Radians, clockwise, about [center].
  final double rotation;

  PhotoLayer moved({Offset? center, double? scale, double? rotation});
}

/// Words on the picture.
@immutable
class TextLayer extends PhotoLayer {
  const TextLayer({
    required super.id,
    required super.center,
    required this.text,
    required this.color,
    this.style = TextStyleKind.plain,
    super.scale,
    super.rotation,
  });

  final String text;
  final Color color;
  final TextStyleKind style;

  /// The size one line is before [scale], as a share of the picture's shorter
  /// side. A share rather than a pixel count, because 56 px is a caption on a
  /// screenshot and an invisible speck on a 12 MP photograph.
  static const double baseFontFraction = 0.09;

  @override
  TextLayer moved({Offset? center, double? scale, double? rotation}) =>
      TextLayer(
        id: id,
        center: center ?? this.center,
        text: text,
        color: color,
        style: style,
        scale: scale ?? this.scale,
        rotation: rotation ?? this.rotation,
      );

  TextLayer copyWith({String? text, Color? color, TextStyleKind? style}) =>
      TextLayer(
        id: id,
        center: center,
        text: text ?? this.text,
        color: color ?? this.color,
        style: style ?? this.style,
        scale: scale,
        rotation: rotation,
      );
}

/// One of the pack's drawings, stuck on the picture.
@immutable
class StickerLayer extends PhotoLayer {
  const StickerLayer({
    required super.id,
    required super.center,
    required this.asset,
    super.scale,
    super.rotation,
  });

  /// The asset path of the **still**, not the animation: an exported JPEG has
  /// one frame, so decoding a loop to draw its first frame would be work for
  /// nothing.
  final String asset;

  /// The side of the square a sticker occupies before [scale], as a share of
  /// the picture's shorter side — same reasoning as the text size.
  static const double baseFraction = 0.32;

  @override
  StickerLayer moved({Offset? center, double? scale, double? rotation}) =>
      StickerLayer(
        id: id,
        center: center ?? this.center,
        asset: asset,
        scale: scale ?? this.scale,
        rotation: rotation ?? this.rotation,
      );
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
    this.rect = full,
    this.quarterTurns = 0,
    this.flipped = false,
  });

  static const none = PhotoCrop();
  static const full = Rect.fromLTWH(0, 0, 1, 1);

  final Rect rect;
  final int quarterTurns;
  final bool flipped;

  bool get isIdentity => rect == full && quarterTurns % 4 == 0 && !flipped;

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

  /// [rect] as it appears on a picture that is already standing up.
  ///
  /// The frame is dragged on the *rotated* preview — turning the photo and
  /// then framing it is the order people work in — but it is stored against
  /// the unrotated image so that turning it again later does not move the cut.
  /// These two convert between the frames, and they are exact rather than
  /// approximate because a quarter turn keeps a rectangle axis-aligned.
  Rect toViewRect(Rect r) => _map(r, quarterTurns, flipped);

  /// The inverse of [toViewRect]: a frame dragged on screen, back into
  /// storage.
  Rect fromViewRect(Rect v) {
    // Undo the mirror first, because the painter applies it last.
    final unmirrored = flipped
        ? Rect.fromLTRB(1 - v.right, v.top, 1 - v.left, v.bottom)
        : v;
    return _map(unmirrored, -quarterTurns, false);
  }

  /// A point on the standing-up, already-cut picture, back to where it is on
  /// the original image.
  ///
  /// The preview shows the *output*: cut, turned, possibly mirrored. Strokes
  /// and layers are stored against the original. Without this the two agree
  /// only while the crop is untouched — turn the photo and every new mark
  /// lands somewhere else, which reads as the pen being broken rather than as
  /// a missing transform.
  Offset outputToImage(Offset q, Size sourceSize) {
    final src = pixels(sourceSize);
    final out = outputSize(sourceSize);
    var v = q - Offset(out.width / 2, out.height / 2);
    // Undo the painter's transform in reverse: mirror, then rotation.
    if (flipped) v = Offset(-v.dx, v.dy);
    v = _turn(v, -quarterTurns);
    return v + Offset(src.width / 2, src.height / 2) + src.topLeft;
  }

  /// A drag *on the preview*, as a movement of the original image.
  ///
  /// A translation, so no centring is involved — but the rotation still is:
  /// pushing a sticker to the right on a picture standing on its side has to
  /// move it down the original.
  Offset viewDeltaToImage(Offset d) =>
      _turn(flipped ? Offset(-d.dx, d.dy) : d, -quarterTurns);

  static Offset _turn(Offset v, int quarterTurns) {
    final turns = ((quarterTurns % 4) + 4) % 4;
    var out = v;
    for (var i = 0; i < turns; i++) {
      out = Offset(-out.dy, out.dx);
    }
    return out;
  }

  /// Rotate a normalised rect about the centre of the unit square, then
  /// mirror it — the order the painter composes its transform in.
  static Rect _map(Rect r, int quarterTurns, bool flipped) {
    var out = r;
    final turns = quarterTurns % 4;
    for (var i = 0; i < (turns < 0 ? turns + 4 : turns); i++) {
      // (x, y) -> (1 - y, x): a quarter turn clockwise of the unit square.
      out = Rect.fromLTRB(1 - out.bottom, out.left, 1 - out.top, out.right);
    }
    if (flipped) {
      out = Rect.fromLTRB(1 - out.right, out.top, 1 - out.left, out.bottom);
    }
    return out;
  }
}

/// Everything an edit is, as one immutable value.
///
/// One value rather than four controllers, because undo has to move all of it
/// together: cropping and then drawing and then undoing twice must put the
/// crop back as well. A stack of these is the whole history — strokes and
/// layers are shared by reference between snapshots, so a step costs a list
/// header rather than a copy of the drawing.
@immutable
class PhotoEdit {
  const PhotoEdit({
    this.strokes = const <Stroke>[],
    this.layers = const <PhotoLayer>[],
    this.adjust = PhotoAdjust.none,
    this.crop = PhotoCrop.none,
  });

  final List<Stroke> strokes;

  /// Stickers and text, in the order they were added — which is the order
  /// they are painted, and therefore what "on top" means.
  final List<PhotoLayer> layers;

  final PhotoAdjust adjust;
  final PhotoCrop crop;

  bool get isUntouched =>
      strokes.isEmpty && layers.isEmpty && adjust.isIdentity && crop.isIdentity;

  PhotoEdit copyWith({
    List<Stroke>? strokes,
    List<PhotoLayer>? layers,
    PhotoAdjust? adjust,
    PhotoCrop? crop,
  }) =>
      PhotoEdit(
        strokes: strokes ?? this.strokes,
        layers: layers ?? this.layers,
        adjust: adjust ?? this.adjust,
        crop: crop ?? this.crop,
      );

  /// The same edit with one layer swapped for a changed version of itself.
  ///
  /// Matched by [PhotoLayer.id] rather than by index: a layer being dragged
  /// while another is deleted would otherwise write over the wrong one.
  PhotoEdit withLayer(PhotoLayer layer) => copyWith(
        layers: <PhotoLayer>[
          for (final l in layers)
            if (l.id == layer.id) layer else l,
        ],
      );

  PhotoEdit withoutLayer(int id) => copyWith(
        layers: <PhotoLayer>[
          for (final l in layers)
            if (l.id != id) l,
        ],
      );

  PhotoLayer? layerById(int id) {
    for (final l in layers) {
      if (l.id == id) return l;
    }
    return null;
  }
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
  /// For a slider being dragged, or a sticker being pushed round the picture:
  /// one snapshot per frame would fill the stack with sixty versions of the
  /// same move, and undo would then take sixty taps to get back. The caller
  /// pushes once when the gesture ends.
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
  final scale =
      math.min(widget.width / image.width, widget.height / image.height);
  final drawn = Size(image.width * scale, image.height * scale);
  final dx = (widget.width - drawn.width) / 2;
  final dy = (widget.height - drawn.height) / 2;
  return Offset((local.dx - dx) / scale, (local.dy - dy) / scale);
}

/// Where a letterboxed picture of [image] actually lands inside a widget of
/// [widget] — the other half of [toImageSpace], and what the crop frame has to
/// be drawn and dragged inside.
Rect fittedRect(Size widget, Size image) {
  if (image.isEmpty || widget.isEmpty) return Offset.zero & widget;
  final scale =
      math.min(widget.width / image.width, widget.height / image.height);
  final drawn = Size(image.width * scale, image.height * scale);
  return Rect.fromLTWH(
    (widget.width - drawn.width) / 2,
    (widget.height - drawn.height) / 2,
    drawn.width,
    drawn.height,
  );
}
