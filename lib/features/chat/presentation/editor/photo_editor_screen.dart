import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/widgets/floating_glass.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../stickers/data/sticker_pack.dart';
import 'photo_edit_model.dart';
import 'photo_edit_render.dart';

/// Which island is open. `none` is the picture with nothing over it.
enum EditorTool { none, crop, draw, adjust }

/// What the brush is doing: a pen on the picture, a sticker, or words.
///
/// Three tabs under one tool rather than three tools in the island, because
/// they share everything that matters — the colour, the selection, the canvas
/// gesture — and because that is the shape people already know from every
/// other photo editor they have used.
enum DrawTab { pen, sticker, text }

/// cubechat's own photo editor.
///
/// It replaces `pro_image_editor`, which was 579 files and 152,000 lines to
/// own for the sake of three tools and a bar that could not be rearranged —
/// its paint editor exposes no hook for a bottom row, so the draw / sticker /
/// text tabs that were asked for could not be put there at all.
///
/// What this is instead: one immutable [PhotoEdit] value, one painter that
/// both the preview and the export use, and three islands. Everything the
/// screen shows is a function of that value, so undo is a stack of values
/// rather than a set of inverse operations each tool has to implement
/// correctly.
class PhotoEditorScreen extends StatefulWidget {
  const PhotoEditorScreen({super.key, required this.source});

  final Uint8List source;

  @override
  State<PhotoEditorScreen> createState() => _PhotoEditorScreenState();
}

class _PhotoEditorScreenState extends State<PhotoEditorScreen> {
  final _history = PhotoEditHistory();
  final _text = TextEditingController();
  final Map<String, ui.Image> _stickers = <String, ui.Image>{};

  ui.Image? _image;
  EditorTool _tool = EditorTool.none;
  DrawTab _tab = DrawTab.pen;
  bool _busy = false;

  // Pen settings, which are not part of the edit: changing the colour is not
  // something to undo.
  Color _color = const Color(0xFFFF3B30);
  double _penWidth = 14;
  PenKind _pen = PenKind.pen;
  TextStyleKind _textStyle = TextStyleKind.plain;

  /// Free, or a locked width/height. Not part of the edit either — it is how
  /// the frame is being dragged, not what was cut.
  double? _ratio;

  /// The stroke being drawn right now, kept out of the history until the
  /// finger lifts — otherwise every pointer move would be an undo step.
  Stroke? _live;

  /// The sticker or text the finger is on.
  int? _selected;
  int _nextLayerId = 1;

  /// What the edit was before the gesture in progress started, so that a drag
  /// or a burst of typing commits as one undo step. See [_beginLive].
  PhotoEdit? _before;

  double _dragScale = 1;
  double _dragRotation = 0;

  @override
  void initState() {
    super.initState();
    _history.addListener(_onEdit);
    _load();
  }

  @override
  void dispose() {
    _history.removeListener(_onEdit);
    _text.dispose();
    _image?.dispose();
    for (final art in _stickers.values) {
      art.dispose();
    }
    _history.dispose();
    super.dispose();
  }

  void _onEdit() => setState(() {});

  Future<void> _load() async {
    final image = await decodeForEditing(widget.source);
    if (!mounted) {
      image.dispose();
      return;
    }
    setState(() => _image = image);
  }

  PhotoEdit get _edit {
    final live = _live;
    if (live == null) return _history.value;
    return _history.value.copyWith(
      strokes: <Stroke>[..._history.value.strokes, live],
    );
  }

  /// What the canvas shows. In crop mode that is the *whole* picture with the
  /// frame drawn over it — showing the cut result there would leave no way to
  /// make the frame bigger again.
  PhotoEdit get _shown {
    final e = _edit;
    if (_tool != EditorTool.crop) return e;
    return e.copyWith(crop: e.crop.copyWith(rect: PhotoCrop.full));
  }

  Size get _sourceSize {
    final image = _image;
    return image == null
        ? Size.zero
        : Size(image.width.toDouble(), image.height.toDouble());
  }

  // ---- one gesture, one undo step -----------------------------------------

  /// Remember where a live gesture started. Idempotent, so a drag that turns
  /// into a pinch mid-way still commits once.
  void _beginLive() => _before ??= _history.value;

  void _commitLive() {
    final before = _before;
    if (before == null) return;
    _before = null;
    final after = _history.value;
    if (identical(before, after)) return;
    // Put the stack back where it was and push the finished state, so undo
    // steps over the whole gesture rather than over each frame of it.
    _history.replace(before);
    _history.push(after);
  }

  // ---- drawing ------------------------------------------------------------

  bool get _drawing => _tool == EditorTool.draw && _tab == DrawTab.pen;

  /// When a finger on the picture moves a sticker or a piece of text.
  ///
  /// Any time except while drawing or cropping — not only inside the tab that
  /// created it. Something you put on a photograph stays yours to move,
  /// resize, turn or take off for as long as the photograph is open; having to
  /// find the tab it came from first is a rule about this program's insides,
  /// and the person is looking at a picture with a cat on it.
  bool get _placing => _tool != EditorTool.crop && !_drawing;

  void _startStroke(Offset image) {
    setState(() {
      _live = Stroke(
        points: <Offset>[image],
        color: _color,
        width: _penWidth,
        kind: _pen,
      );
    });
  }

  void _extendStroke(Offset image) {
    final live = _live;
    if (live == null) return;
    setState(() {
      _live = Stroke(
        points: <Offset>[...live.points, image],
        color: live.color,
        width: live.width,
        kind: live.kind,
      );
    });
  }

  void _endStroke() {
    final live = _live;
    if (live == null) return;
    _live = null;
    _history.push(
      _history.value.copyWith(
        strokes: <Stroke>[..._history.value.strokes, live],
      ),
    );
  }

  // ---- stickers and text --------------------------------------------------

  Offset get _pictureCentre => _history.value.crop.pixels(_sourceSize).center;

  Future<void> _addSticker(String name) async {
    final path = StickerPack.still(name);
    if (!_stickers.containsKey(path)) {
      final art = await decodeAssetImage(path);
      if (!mounted) {
        art.dispose();
        return;
      }
      _stickers[path] = art;
    }
    final layer = StickerLayer(
      id: _nextLayerId++,
      center: _pictureCentre,
      asset: path,
    );
    setState(() => _selected = layer.id);
    _history.push(
      _history.value.copyWith(
        layers: <PhotoLayer>[..._history.value.layers, layer],
      ),
    );
  }

  /// The text layer the field is bound to, if the selection is one.
  TextLayer? get _activeText {
    final id = _selected;
    if (id == null) return null;
    final layer = _history.value.layerById(id);
    return layer is TextLayer ? layer : null;
  }

  void _openTextTab() {
    final existing = _activeText;
    if (existing != null) {
      _text.text = existing.text;
      return;
    }
    final layer = TextLayer(
      id: _nextLayerId++,
      center: _pictureCentre,
      text: '',
      color: _color,
      style: _textStyle,
    );
    _text.clear();
    _selected = layer.id;
    _history.push(
      _history.value.copyWith(
        layers: <PhotoLayer>[..._history.value.layers, layer],
      ),
    );
  }

  /// Drop an empty text layer when the tab is left.
  ///
  /// Otherwise opening the tab and changing your mind leaves an invisible
  /// thing on the picture that still catches every tap meant for whatever is
  /// under it.
  void _closeTextTab() {
    final layer = _activeText;
    if (layer == null || layer.text.trim().isNotEmpty) {
      _commitLive();
      return;
    }
    _before = null;
    _history.push(_history.value.withoutLayer(layer.id));
    _selected = null;
  }

  void _onTextChanged(String value) {
    final layer = _activeText;
    if (layer == null) return;
    _beginLive();
    _history.replace(_history.value.withLayer(layer.copyWith(text: value)));
  }

  void _setColor(Color c) {
    setState(() => _color = c);
    final layer = _activeText;
    if (layer == null) return;
    _beginLive();
    _history.replace(_history.value.withLayer(layer.copyWith(color: c)));
  }

  void _setTextStyle(TextStyleKind style) {
    setState(() => _textStyle = style);
    final layer = _activeText;
    if (layer == null) return;
    _beginLive();
    _history.replace(_history.value.withLayer(layer.copyWith(style: style)));
  }

  void _removeSelected() {
    final id = _selected;
    if (id == null) return;
    _before = null;
    setState(() => _selected = null);
    _text.clear();
    _history.push(_history.value.withoutLayer(id));
  }

  // ---- moving a layer -----------------------------------------------------

  void _layerDown(Offset image) {
    final hit = _hitTest(image);
    setState(() => _selected = hit?.id);
    if (hit is TextLayer) {
      _text.text = hit.text;
      _textStyle = hit.style;
    }
    _dragScale = hit?.scale ?? 1;
    _dragRotation = hit?.rotation ?? 0;
    if (hit != null) _beginLive();
  }

  void _layerMove(Offset deltaImage, double scale, double rotation) {
    final id = _selected;
    if (id == null) return;
    final layer = _history.value.layerById(id);
    if (layer == null) return;
    _history.replace(
      _history.value.withLayer(
        layer.moved(
          center: layer.center + deltaImage,
          scale: (_dragScale * scale).clamp(0.12, 10.0),
          rotation: _dragRotation +
              (_history.value.crop.flipped ? -rotation : rotation),
        ),
      ),
    );
  }

  /// The topmost layer under a point, un-rotating the point about each layer
  /// so that a tilted sticker is caught where it is drawn and not by its
  /// upright bounding box.
  PhotoLayer? _hitTest(Offset image) {
    final img = _image;
    if (img == null) return null;
    final painter = PhotoEditPainter(
      image: img,
      edit: _history.value,
      stickers: _stickers,
    );
    for (final layer in _history.value.layers.reversed) {
      var local = image - layer.center;
      if (layer.rotation != 0) {
        final c = math.cos(-layer.rotation);
        final s = math.sin(-layer.rotation);
        local = Offset(
          local.dx * c - local.dy * s,
          local.dx * s + local.dy * c,
        );
      }
      final b = painter.layerBounds(layer);
      if (local.dx.abs() <= b.width / 2 && local.dy.abs() <= b.height / 2) {
        return layer;
      }
    }
    return null;
  }

  // ---- done ---------------------------------------------------------------

  Future<void> _confirm() async {
    final image = _image;
    if (image == null || _busy) return;
    _commitLive();
    // Nothing was changed: hand back the bytes that came in rather than a
    // re-encode of them. A round trip through the JPEG encoder for an edit
    // nobody made costs quality for no reason, and it is the common case —
    // this screen is also the preview.
    if (_history.isUntouched) {
      Navigator.of(context).pop(widget.source);
      return;
    }
    setState(() => _busy = true);
    try {
      final bytes = await renderEdit(
        PhotoEditPainter(
          image: image,
          edit: _history.value,
          stickers: _stickers,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(bytes);
    } catch (_) {
      // Never leave somebody stuck on a screen that will not close: the
      // original is a worse answer than the edit and a much better one than a
      // frozen editor.
      if (mounted) Navigator.of(context).pop(widget.source);
    }
  }

  void _pickTool(EditorTool tool) {
    if (_tool == EditorTool.draw && _tab == DrawTab.text) _closeTextTab();
    setState(() {
      _tool = _tool == tool ? EditorTool.none : tool;
      // The selection survives closing the panel. It used to be dropped here,
      // which is what made a sticker unreachable the moment the brush was put
      // away — see [_placing]. Cropping is the exception: the frame owns every
      // touch on the picture while it is up.
      if (_tool == EditorTool.crop) _selected = null;
    });
  }

  /// Bring the text tab back up on the piece of text that is selected.
  void _editSelectedText() {
    if (_activeText == null) return;
    setState(() {
      _tool = EditorTool.draw;
      _tab = DrawTab.text;
      _openTextTab();
    });
  }

  void _pickTab(DrawTab tab) {
    if (_tab == tab) return;
    if (_tab == DrawTab.text) _closeTextTab();
    setState(() {
      _tab = tab;
      if (tab == DrawTab.pen) _selected = null;
    });
    if (tab == DrawTab.text) setState(_openTextTab);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final image = _image;
    // Sliders in the app's colour, not Material's default purple. A control
    // that is the wrong colour reads as belonging to something else, and this
    // screen already has to look like part of the app rather than like the
    // editor it replaced.
    return SliderTheme(
      data: SliderThemeData(
        activeTrackColor: AppColors.brandPrimary,
        inactiveTrackColor: Colors.white24,
        thumbColor: AppColors.brandPrimary,
        overlayColor: AppColors.brandPrimary.withValues(alpha: 0.15),
        trackHeight: 3,
      ),
      child: Scaffold(
        backgroundColor: AppColors.bgDeep,
        body: image == null
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: Column(
                  children: [
                    _TopBar(
                      canUndo: _history.canUndo,
                      canRedo: _history.canRedo,
                      busy: _busy,
                      onClose: () => Navigator.of(context).pop(),
                      onUndo: _history.undo,
                      onRedo: _history.redo,
                      onDone: _confirm,
                    ),
                    Expanded(child: _stage(image)),
                    _animatedPanel(t),
                    _Island(tool: _tool, onPick: _pickTool, t: t),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _stage(ui.Image image) {
    final id = _selected;
    final selected = id == null ? null : _history.value.layerById(id);
    return Stack(
      children: [
        Positioned.fill(
          child: _Canvas(
            image: image,
            edit: _shown,
            stickers: _stickers,
            selected: _placing ? selected : null,
            drawing: _drawing,
            placing: _placing,
            onStrokeStart: _startStroke,
            onStrokeMove: _extendStroke,
            onStrokeEnd: _endStroke,
            onLayerDown: _layerDown,
            onLayerMove: _layerMove,
            onLayerUp: _commitLive,
          ),
        ),
        if (_tool == EditorTool.crop)
          Positioned.fill(
            child: _CropOverlay(
              sourceSize: _sourceSize,
              crop: _history.value.crop,
              ratio: _ratio,
              onChanged: (view) {
                _beginLive();
                final crop = _history.value.crop;
                _history.replace(
                  _history.value.copyWith(
                    crop: crop.copyWith(rect: crop.fromViewRect(view)),
                  ),
                );
              },
              onCommit: _commitLive,
            ),
          ),
        if (_drawing)
          Positioned(
            left: 0,
            top: 24,
            bottom: 24,
            child: _WidthRail(
              value: _penWidth,
              color: _pen == PenKind.eraser ? Colors.white : _color,
              onChanged: (w) => setState(() => _penWidth = w),
            ),
          ),
      ],
    );
  }

  /// The tool that just opened, rising into place.
  ///
  /// Two animations, and they do different jobs. [AnimatedSwitcher] fades and
  /// lifts the new panel in; [AnimatedSize] moves the picture above it, which
  /// is the half that stops the photograph from jumping when a two-row panel
  /// replaces a one-row one. Without it the switch is smooth and the whole
  /// screen still snaps.
  ///
  /// Keyed on what is showing rather than on the widget type: the text panel
  /// holds a focused field, and a key that changed while somebody typed would
  /// rebuild it and take the keyboard away mid-word.
  Widget _animatedPanel(AppLocalizations t) {
    final key = ValueKey<String>(
      '${_tool.name}/${_tab.name}/${_selected != null}',
    );
    return AnimatedSize(
      duration: const Duration(milliseconds: 190),
      curve: Curves.easeOutCubic,
      alignment: Alignment.bottomCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 190),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeIn,
        // Out first, then in. Cross-fading two panels of different heights
        // over each other makes the taller one's bottom row appear through
        // the shorter one, which reads as a rendering fault.
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.bottomCenter,
          children: <Widget>[...previous, if (current != null) current],
        ),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.22),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: KeyedSubtree(key: key, child: _panel(t)),
      ),
    );
  }

  Widget _panel(AppLocalizations t) {
    switch (_tool) {
      case EditorTool.none:
        // With no panel up, the picture is still live: tapping a sticker or a
        // line of text selects it, and this is where what you can then do to
        // it appears.
        final id = _selected;
        final layer = id == null ? null : _history.value.layerById(id);
        if (layer == null) return const SizedBox(height: 8);
        return _LayerActions(
          t: t,
          isText: layer is TextLayer,
          onEdit: _editSelectedText,
          onRemove: _removeSelected,
          onDone: () => setState(() => _selected = null),
        );
      case EditorTool.draw:
        return _DrawPanel(
          t: t,
          tab: _tab,
          onTab: _pickTab,
          color: _color,
          onColor: _setColor,
          pen: _pen,
          onPen: (p) => setState(() => _pen = p),
          textStyle: _textStyle,
          onTextStyle: _setTextStyle,
          textController: _text,
          onText: _onTextChanged,
          onSticker: _addSticker,
          canRemove: _selected != null,
          onRemove: _removeSelected,
        );
      case EditorTool.adjust:
        return _AdjustPanel(
          value: _history.value.adjust,
          t: t,
          onChanged: (a) => _history.replace(
            _history.value.copyWith(adjust: a),
          ),
          onCommitted: (a) => _history.push(
            _history.value.copyWith(adjust: a),
          ),
        );
      case EditorTool.crop:
        return _CropPanel(
          value: _history.value.crop,
          ratio: _ratio,
          onRatio: _setRatio,
          onChanged: (c) => _history.push(_history.value.copyWith(crop: c)),
          // Live while the slider moves, one step when it stops — the same
          // deal the adjustment sliders get, and for the same reason.
          onTilt: (v) {
            _beginLive();
            _history.replace(
              _history.value.copyWith(
                crop: _history.value.crop.copyWith(tilt: v),
              ),
            );
          },
          onTiltEnd: (v) {
            // Idempotent, so this is the drag's own start when there was one
            // and the tap's own start when the level button was pressed cold.
            _beginLive();
            _history.replace(
              _history.value.copyWith(
                crop: _history.value.crop.copyWith(tilt: v),
              ),
            );
            _commitLive();
          },
        );
    }
  }

  void _setRatio(double? r) {
    setState(() => _ratio = r);
    if (r == null) return;
    // Snap the frame to the shape straight away: a ratio button that only
    // takes effect on the next drag reads as not having worked.
    final crop = _history.value.crop;
    _history.push(
      _history.value.copyWith(
        crop: crop.copyWith(rect: crop.fromViewRect(_centredRatio(crop, r))),
      ),
    );
  }

  /// The largest rect of [ratio] that fits the standing-up picture, centred.
  Rect _centredRatio(PhotoCrop crop, double ratio) {
    final out = crop.copyWith(rect: PhotoCrop.full).outputSize(_sourceSize);
    if (out.isEmpty) return PhotoCrop.full;
    var w = out.width;
    var h = w / ratio;
    if (h > out.height) {
      h = out.height;
      w = h * ratio;
    }
    return Rect.fromLTWH(
      (out.width - w) / 2 / out.width,
      (out.height - h) / 2 / out.height,
      w / out.width,
      h / out.height,
    );
  }
}

/// Close, undo, redo, done — the four that are always available.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.canUndo,
    required this.canRedo,
    required this.busy,
    required this.onClose,
    required this.onUndo,
    required this.onRedo,
    required this.onDone,
  });

  final bool canUndo;
  final bool canRedo;
  final bool busy;
  final VoidCallback onClose;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      child: Row(
        children: [
          // Material's own icons rather than the Symbols ones, which came back
          // from a phone as an empty circle where the arrow should be. The
          // glyph is in the subset font the APK ships, so the tree shaker is
          // not eating it — but a chrome control that might not draw is not
          // worth the consistency argument, and every other back button in the
          // app is already this icon.
          _CircleAction(icon: Icons.arrow_back_rounded, onTap: onClose),
          const Spacer(),
          _CircleAction(
            icon: Icons.undo_rounded,
            onTap: canUndo ? onUndo : null,
          ),
          const SizedBox(width: 8),
          _CircleAction(
            icon: Icons.redo_rounded,
            onTap: canRedo ? onRedo : null,
          ),
          const SizedBox(width: 8),
          _CircleAction(
            icon: Icons.check_rounded,
            onTap: busy ? null : onDone,
            filled: true,
          ),
        ],
      ),
    );
  }
}

/// A glyph in a translucent disc.
///
/// The disc is the point: these sit over a photograph, and a bare white glyph
/// on a bright picture is invisible — reported as a back button that was not
/// there, when it was drawn and simply could not be seen.
class _CircleAction extends StatelessWidget {
  const _CircleAction({
    required this.icon,
    required this.onTap,
    this.filled = false,
    this.size = 22,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final bool filled;
  final double size;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: filled
          ? AppColors.brandPrimary.withValues(alpha: enabled ? 0.92 : 0.35)
          : Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      // Material animates its own colour when told how long to take, so a pen
      // becoming the chosen one fades rather than flicks. Free: no controller,
      // no ticker outside the transition.
      animationDuration: const Duration(milliseconds: 160),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: AnimatedScale(
            scale: filled ? 1.1 : 1,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutBack,
            child: Icon(
              icon,
              size: size,
              color: filled
                  ? AppColors.bgDeep
                  : Colors.white.withValues(alpha: enabled ? 1 : 0.35),
            ),
          ),
        ),
      ),
    );
  }
}

/// The picture, and the finger on it.
class _Canvas extends StatelessWidget {
  const _Canvas({
    required this.image,
    required this.edit,
    required this.stickers,
    required this.selected,
    required this.drawing,
    required this.placing,
    required this.onStrokeStart,
    required this.onStrokeMove,
    required this.onStrokeEnd,
    required this.onLayerDown,
    required this.onLayerMove,
    required this.onLayerUp,
  });

  final ui.Image image;
  final PhotoEdit edit;
  final Map<String, ui.Image> stickers;
  final PhotoLayer? selected;
  final bool drawing;
  final bool placing;
  final void Function(Offset image) onStrokeStart;
  final void Function(Offset image) onStrokeMove;
  final VoidCallback onStrokeEnd;
  final void Function(Offset image) onLayerDown;
  final void Function(Offset delta, double scale, double rotation) onLayerMove;
  final VoidCallback onLayerUp;

  @override
  Widget build(BuildContext context) {
    final painter = PhotoEditPainter(
      image: image,
      edit: edit,
      stickers: stickers,
    );
    final out = painter.outputSize;
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        final area = fittedRect(box, out);
        final scale = out.isEmpty || area.width <= 0 ? 1.0 : area.width / out.width;

        // Two conversions, and they are not the same one. A *position* goes
        // through the crop and the rotation; a *delta* only through the
        // rotation. Using the first for a drag would move a sticker by the
        // crop offset on every frame.
        Offset at(Offset local) => edit.crop.outputToImage(
              toImageSpace(local, box, out),
              painter.sourceSize,
            );
        Offset by(Offset delta) =>
            edit.crop.viewDeltaToImage(delta / scale, painter.sourceSize);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart:
              drawing ? (d) => onStrokeStart(at(d.localPosition)) : null,
          onPanUpdate:
              drawing ? (d) => onStrokeMove(at(d.localPosition)) : null,
          onPanEnd: drawing ? (_) => onStrokeEnd() : null,
          // Scale rather than pan for the layers, because it is one
          // recogniser: a drag that becomes a pinch has to keep working, and
          // two competing recognisers on one box means whichever wins the
          // arena eats the gesture.
          onScaleStart:
              placing ? (d) => onLayerDown(at(d.localFocalPoint)) : null,
          onScaleUpdate: placing
              ? (d) => onLayerMove(by(d.focalPointDelta), d.scale, d.rotation)
              : null,
          onScaleEnd: placing ? (_) => onLayerUp() : null,
          child: CustomPaint(
            size: box,
            painter: _EditPainter(painter, selected),
            isComplex: true,
          ),
        );
      },
    );
  }
}

class _EditPainter extends CustomPainter {
  const _EditPainter(this.edit, this.selected);

  final PhotoEditPainter edit;
  final PhotoLayer? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final out = edit.outputSize;
    if (out.isEmpty) return;
    final scale = (size.width / out.width) < (size.height / out.height)
        ? size.width / out.width
        : size.height / out.height;
    if (scale <= 0) return;
    canvas.save();
    canvas.translate(
      (size.width - out.width * scale) / 2,
      (size.height - out.height * scale) / 2,
    );
    canvas.scale(scale);
    edit.paint(canvas);
    final chosen = selected;
    // Two logical pixels, whatever the picture's size.
    if (chosen != null) edit.paintSelection(canvas, chosen, 2 / scale);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_EditPainter old) =>
      !identical(old.edit.edit, edit.edit) ||
      !identical(old.edit.image, edit.image) ||
      !identical(old.selected, selected);
}

/// The frame that says what will be kept.
///
/// Dragged on the *standing-up* picture — turning a photo and then framing it
/// is the order people work in — while the cut itself is stored against the
/// original. Both conversions live on [PhotoCrop]; this widget only knows
/// pixels.
class _CropOverlay extends StatefulWidget {
  const _CropOverlay({
    required this.sourceSize,
    required this.crop,
    required this.ratio,
    required this.onChanged,
    required this.onCommit,
  });

  final Size sourceSize;
  final PhotoCrop crop;
  final double? ratio;
  final void Function(Rect viewRect) onChanged;
  final VoidCallback onCommit;

  @override
  State<_CropOverlay> createState() => _CropOverlayState();
}

enum _Handle { move, tl, tr, bl, br, left, right, top, bottom }

class _CropOverlayState extends State<_CropOverlay> {
  _Handle _handle = _Handle.move;

  /// How close a finger has to be to an edge to grab it rather than the frame.
  /// A hair over a fingertip: smaller and the corners are unhittable, larger
  /// and a small frame is all corner and cannot be moved at all.
  static const double _grab = 30;

  /// Never let the frame close up to nothing — a zero-sized crop asks the
  /// compositor for a zero-sized surface, and past that it is not a picture
  /// any more.
  static const double _minSide = 56;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        final out = widget.crop
            .copyWith(rect: PhotoCrop.full)
            .outputSize(widget.sourceSize);
        final area = fittedRect(box, out);
        final view = widget.crop.toViewRect(widget.crop.rect);
        final frame = Rect.fromLTRB(
          area.left + view.left * area.width,
          area.top + view.top * area.height,
          area.left + view.right * area.width,
          area.top + view.bottom * area.height,
        );

        void emit(Rect next) {
          if (area.width <= 0 || area.height <= 0) return;
          widget.onChanged(
            Rect.fromLTRB(
              (next.left - area.left) / area.width,
              (next.top - area.top) / area.height,
              (next.right - area.left) / area.width,
              (next.bottom - area.top) / area.height,
            ),
          );
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => _handle = _grabbed(d.localPosition, frame),
          onPanUpdate: (d) =>
              emit(_resize(frame, _handle, d.delta, area, widget.ratio)),
          onPanEnd: (_) => widget.onCommit(),
          child: CustomPaint(
            size: box,
            painter: _CropFramePainter(frame: frame, area: area),
          ),
        );
      },
    );
  }

  _Handle _grabbed(Offset p, Rect f) {
    final nearL = (p.dx - f.left).abs() < _grab;
    final nearR = (p.dx - f.right).abs() < _grab;
    final nearT = (p.dy - f.top).abs() < _grab;
    final nearB = (p.dy - f.bottom).abs() < _grab;
    if (nearL && nearT) return _Handle.tl;
    if (nearR && nearT) return _Handle.tr;
    if (nearL && nearB) return _Handle.bl;
    if (nearR && nearB) return _Handle.br;
    final insideY = p.dy > f.top - _grab && p.dy < f.bottom + _grab;
    final insideX = p.dx > f.left - _grab && p.dx < f.right + _grab;
    if (nearL && insideY) return _Handle.left;
    if (nearR && insideY) return _Handle.right;
    if (nearT && insideX) return _Handle.top;
    if (nearB && insideX) return _Handle.bottom;
    return _Handle.move;
  }

  static Rect _resize(
    Rect f,
    _Handle h,
    Offset d,
    Rect bounds,
    double? ratio,
  ) {
    if (h == _Handle.move) {
      final dx = d.dx.clamp(bounds.left - f.left, bounds.right - f.right);
      final dy = d.dy.clamp(bounds.top - f.top, bounds.bottom - f.bottom);
      return f.shift(Offset(dx, dy));
    }

    var l = f.left;
    var t = f.top;
    var r = f.right;
    var b = f.bottom;
    switch (h) {
      case _Handle.tl:
        l += d.dx;
        t += d.dy;
      case _Handle.tr:
        r += d.dx;
        t += d.dy;
      case _Handle.bl:
        l += d.dx;
        b += d.dy;
      case _Handle.br:
        r += d.dx;
        b += d.dy;
      case _Handle.left:
        l += d.dx;
      case _Handle.right:
        r += d.dx;
      case _Handle.top:
        t += d.dy;
      case _Handle.bottom:
        b += d.dy;
      case _Handle.move:
        break;
    }
    l = l.clamp(bounds.left, r - _minSide);
    t = t.clamp(bounds.top, b - _minSide);
    r = r.clamp(l + _minSide, bounds.right);
    b = b.clamp(t + _minSide, bounds.bottom);
    final free = Rect.fromLTRB(l, t, r, b);
    return ratio == null ? free : _lock(free, h, ratio, bounds);
  }

  /// Force [r] to [ratio], anchored on the side the finger is *not* holding,
  /// then slide it back inside the picture if that pushed it out.
  static Rect _lock(Rect r, _Handle h, double ratio, Rect bounds) {
    final byHeight = h == _Handle.top || h == _Handle.bottom;
    var w = byHeight ? r.height * ratio : r.width;
    var hgt = byHeight ? r.height : r.width / ratio;
    if (w > bounds.width) {
      w = bounds.width;
      hgt = w / ratio;
    }
    if (hgt > bounds.height) {
      hgt = bounds.height;
      w = hgt * ratio;
    }
    final double left;
    final double top;
    switch (h) {
      case _Handle.tl:
        left = r.right - w;
        top = r.bottom - hgt;
      case _Handle.tr:
        left = r.left;
        top = r.bottom - hgt;
      case _Handle.bl:
        left = r.right - w;
        top = r.top;
      case _Handle.br:
      case _Handle.move:
        left = r.left;
        top = r.top;
      case _Handle.left:
        left = r.right - w;
        top = r.center.dy - hgt / 2;
      case _Handle.right:
        left = r.left;
        top = r.center.dy - hgt / 2;
      case _Handle.top:
        left = r.center.dx - w / 2;
        top = r.bottom - hgt;
      case _Handle.bottom:
        left = r.center.dx - w / 2;
        top = r.top;
    }
    return Rect.fromLTWH(
      left.clamp(bounds.left, bounds.right - w),
      top.clamp(bounds.top, bounds.bottom - hgt),
      w,
      hgt,
    );
  }
}

/// Dim outside, thirds inside, brackets on the corners.
class _CropFramePainter extends CustomPainter {
  const _CropFramePainter({required this.frame, required this.area});

  final Rect frame;
  final Rect area;

  @override
  void paint(Canvas canvas, Size size) {
    // The shade covers the picture only, not the black around it: dimming the
    // letterbox as well makes the photo look smaller than it is.
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(area),
        Path()..addRect(frame),
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );

    final hair = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (var i = 1; i < 3; i++) {
      final x = frame.left + frame.width * i / 3;
      final y = frame.top + frame.height * i / 3;
      canvas.drawLine(Offset(x, frame.top), Offset(x, frame.bottom), hair);
      canvas.drawLine(Offset(frame.left, y), Offset(frame.right, y), hair);
    }
    canvas.drawRect(
      frame,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.85)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );

    // Brackets, so the corners look grabbable — what a finger aims at has to
    // be visible, or the frame reads as fixed.
    final bracket = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final arm = math.min(24.0, math.min(frame.width, frame.height) / 3);
    for (final corner in <List<Offset>>[
      <Offset>[frame.topLeft, Offset(arm, 0), Offset(0, arm)],
      <Offset>[frame.topRight, Offset(-arm, 0), Offset(0, arm)],
      <Offset>[frame.bottomLeft, Offset(arm, 0), Offset(0, -arm)],
      <Offset>[frame.bottomRight, Offset(-arm, 0), Offset(0, -arm)],
    ]) {
      canvas.drawLine(corner[0], corner[0] + corner[1], bracket);
      canvas.drawLine(corner[0], corner[0] + corner[2], bracket);
    }
  }

  @override
  bool shouldRepaint(_CropFramePainter old) =>
      old.frame != frame || old.area != area;
}

/// The pen thickness, as a line down the side of the picture.
///
/// Down the side rather than in the panel because the panel is already three
/// rows deep in draw mode, and because a control under your hand while you are
/// drawing is one you can reach without looking away from the mark you just
/// made. It sits nearly invisible until it is touched, then opens.
class _WidthRail extends StatefulWidget {
  const _WidthRail({
    required this.value,
    required this.color,
    required this.onChanged,
  });

  final double value;
  final Color color;
  final void Function(double) onChanged;

  static const double min = 4;
  static const double max = 48;

  @override
  State<_WidthRail> createState() => _WidthRailState();
}

class _WidthRailState extends State<_WidthRail> {
  bool _held = false;

  @override
  Widget build(BuildContext context) {
    const span = _WidthRail.max - _WidthRail.min;
    final fraction = ((widget.value - _WidthRail.min) / span).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (_) => setState(() => _held = true),
          onVerticalDragEnd: (_) => setState(() => _held = false),
          onVerticalDragCancel: () => setState(() => _held = false),
          onVerticalDragUpdate: (d) {
            if (height <= 0) return;
            // Up is thicker, which is the way every size control on a phone
            // reads, and the way the finger already moves to reach the top of
            // the rail.
            final next = widget.value - d.delta.dy / height * span * 1.6;
            widget.onChanged(next.clamp(_WidthRail.min, _WidthRail.max));
          },
          child: SizedBox(
            width: 46,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(width: 12),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  width: _held ? 10 : 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: _held ? 0.22 : 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Column(
                    children: [
                      Expanded(
                        flex: math.max(1, 1000 - (fraction * 1000).round()),
                        child: const SizedBox.shrink(),
                      ),
                      Expanded(
                        flex: math.max(1, (fraction * 1000).round()),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_held)
                  Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Align(
                      alignment: Alignment(0, 1 - fraction * 2),
                      child: Container(
                        width: widget.value,
                        height: widget.value,
                        decoration: BoxDecoration(
                          color: widget.color,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white70),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// What you can do to the sticker or the words you just tapped.
///
/// Shown in the panel slot when no tool is open, so that a thing put on the
/// picture stays reachable after the brush is put away — the alternative was
/// re-opening the tab that made it, which is a rule about this program rather
/// than about photographs.
class _LayerActions extends StatelessWidget {
  const _LayerActions({
    required this.t,
    required this.isText,
    required this.onEdit,
    required this.onRemove,
    required this.onDone,
  });

  final AppLocalizations t;
  final bool isText;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Center(
        child: FloatingGlass(
          borderRadius: 22,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isText) ...[
                Tooltip(
                  message: t.editorTabText,
                  child: _CircleAction(
                    icon: Icons.text_fields_rounded,
                    onTap: onEdit,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Tooltip(
                message: t.editorRemove,
                child: _CircleAction(
                  icon: Icons.delete_rounded,
                  onTap: onRemove,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              _CircleAction(
                icon: Icons.check_rounded,
                onTap: onDone,
                filled: true,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The three tools, as the island the rest of the app is built from.
class _Island extends StatelessWidget {
  const _Island({required this.tool, required this.onPick, required this.t});

  final EditorTool tool;
  final void Function(EditorTool) onPick;
  final AppLocalizations t;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: Center(
        child: FloatingGlass(
          borderRadius: 28,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _IslandTool(
                icon: Icons.crop_rotate_rounded,
                tooltip: t.editorToolCrop,
                active: tool == EditorTool.crop,
                onTap: () => onPick(EditorTool.crop),
              ),
              _IslandTool(
                icon: Icons.brush_rounded,
                tooltip: t.editorToolDraw,
                active: tool == EditorTool.draw,
                onTap: () => onPick(EditorTool.draw),
              ),
              _IslandTool(
                icon: Icons.tune_rounded,
                tooltip: t.editorToolAdjust,
                active: tool == EditorTool.adjust,
                onTap: () => onPick(EditorTool.adjust),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IslandTool extends StatelessWidget {
  const _IslandTool({
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active
            ? AppColors.brandPrimary.withValues(alpha: 0.18)
            : Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        animationDuration: const Duration(milliseconds: 190),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: AnimatedScale(
              scale: active ? 1.12 : 1,
              duration: const Duration(milliseconds: 190),
              curve: Curves.easeOutBack,
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: active ? 1 : 0),
                duration: const Duration(milliseconds: 190),
                builder: (context, t, _) => Icon(
                  icon,
                  size: 26,
                  color: Color.lerp(
                    AppColors.textOnGlass,
                    AppColors.brandPrimary,
                    t,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The brush, in three tabs: pens, stickers, words.
class _DrawPanel extends StatelessWidget {
  const _DrawPanel({
    required this.t,
    required this.tab,
    required this.onTab,
    required this.color,
    required this.onColor,
    required this.pen,
    required this.onPen,
    required this.textStyle,
    required this.onTextStyle,
    required this.textController,
    required this.onText,
    required this.onSticker,
    required this.canRemove,
    required this.onRemove,
  });

  final AppLocalizations t;
  final DrawTab tab;
  final void Function(DrawTab) onTab;
  final Color color;
  final void Function(Color) onColor;
  final PenKind pen;
  final void Function(PenKind) onPen;
  final TextStyleKind textStyle;
  final void Function(TextStyleKind) onTextStyle;
  final TextEditingController textController;
  final void Function(String) onText;
  final void Function(String) onSticker;
  final bool canRemove;
  final VoidCallback onRemove;

  /// Evenly spread round the wheel, plus the two ends of the greyscale.
  ///
  /// Eight rather than six, and laid out with the space divided between them
  /// instead of a fixed gap after each: the old row was six swatches pushed
  /// against the left edge with a hole on the right.
  static const palette = <Color>[
    Color(0xFFFFFFFF),
    Color(0xFF1C1C1E),
    Color(0xFFFF3B30),
    Color(0xFFFF9500),
    Color(0xFFFFCC00),
    Color(0xFF34C759),
    Color(0xFF0A84FF),
    Color(0xFFAF52DE),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: FloatingGlass(
        borderRadius: 22,
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _tabs(),
            const SizedBox(height: 8),
            switch (tab) {
              DrawTab.pen => _pens(),
              DrawTab.sticker => _stickerStrip(),
              DrawTab.text => _textRow(),
            },
            const SizedBox(height: 8),
            // No palette under the stickers: a colour would do nothing there,
            // and a control that does nothing is worse than a missing one.
            // The bin still has to be reachable, so it stays.
            if (tab == DrawTab.sticker)
              _stickerActions()
            else
              _colours(),
          ],
        ),
      ),
    );
  }

  Widget _stickerActions() {
    if (!canRemove) return const SizedBox(height: 4);
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: <Widget>[
        Tooltip(
          message: t.editorRemove,
          child: _CircleAction(
            icon: Icons.delete_rounded,
            onTap: onRemove,
            size: 18,
          ),
        ),
      ],
    );
  }

  Widget _tabs() {
    final labels = <DrawTab, String>{
      DrawTab.pen: t.editorToolDraw,
      DrawTab.sticker: t.editorTabSticker,
      DrawTab.text: t.editorTabText,
    };
    return Row(
      children: <Widget>[
        for (final entry in labels.entries)
          Expanded(
            child: GestureDetector(
              onTap: () => onTab(entry.key),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  children: [
                    Text(
                      entry.value.toUpperCase(),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        letterSpacing: 0.6,
                        fontWeight: FontWeight.w600,
                        color: tab == entry.key
                            ? AppColors.brandPrimary
                            : AppColors.textOnGlassDim,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Container(
                      height: 2,
                      decoration: BoxDecoration(
                        color: tab == entry.key
                            ? AppColors.brandPrimary
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _pens() {
    final kinds = <PenKind, (IconData, String)>{
      PenKind.pen: (Icons.edit_rounded, t.editorPenPen),
      PenKind.marker: (Icons.border_color_rounded, t.editorPenMarker),
      PenKind.neon: (Icons.auto_awesome_rounded, t.editorPenNeon),
      PenKind.arrow: (Icons.north_east_rounded, t.editorPenArrow),
      PenKind.blur: (Icons.blur_on_rounded, t.editorPenBlur),
      PenKind.eraser: (Icons.cleaning_services_rounded, t.editorPenEraser),
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        for (final entry in kinds.entries)
          Tooltip(
            message: entry.value.$2,
            child: _CircleAction(
              icon: entry.value.$1,
              onTap: () => onPen(entry.key),
              filled: pen == entry.key,
              size: 20,
            ),
          ),
      ],
    );
  }

  Widget _stickerStrip() {
    return SizedBox(
      height: 68,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: StickerPack.all.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final name = StickerPack.all[i];
          // Decoded at the size it is drawn, the way the picker grid does it:
          // seventy-two full-size decodes to fill one strip is exactly the
          // cost this codebase keeps taking back out.
          final pixels = (64 * MediaQuery.devicePixelRatioOf(context)).round();
          return GestureDetector(
            onTap: () => onSticker(name),
            child: Image.asset(
              StickerPack.still(name),
              width: 64,
              height: 64,
              cacheWidth: pixels,
              cacheHeight: pixels,
              filterQuality: FilterQuality.medium,
            ),
          );
        },
      ),
    );
  }

  Widget _textRow() {
    final styles = <TextStyleKind, IconData>{
      TextStyleKind.plain: Icons.text_fields_rounded,
      TextStyleKind.filled: Icons.format_color_fill_rounded,
      TextStyleKind.outlined: Icons.format_color_text_rounded,
    };
    return Row(
      children: <Widget>[
        Expanded(
          child: TextField(
            controller: textController,
            onChanged: onText,
            autofocus: true,
            minLines: 1,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            style: TextStyle(color: AppColors.textOnGlass, fontSize: 15),
            decoration: InputDecoration(
              isDense: true,
              hintText: t.editorTextHint,
              hintStyle: TextStyle(color: AppColors.textOnGlassDim),
              border: InputBorder.none,
            ),
          ),
        ),
        for (final entry in styles.entries)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: _CircleAction(
              icon: entry.value,
              onTap: () => onTextStyle(entry.key),
              filled: textStyle == entry.key,
              size: 18,
            ),
          ),
      ],
    );
  }

  Widget _colours() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        for (final c in palette)
          GestureDetector(
            onTap: () => onColor(c),
            child: Container(
              width: 30,
              height: 30,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: c == color ? Colors.white : Colors.transparent,
                  width: 2,
                ),
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white24),
                ),
              ),
            ),
          ),
        if (canRemove)
          Tooltip(
            message: t.editorRemove,
            child: _CircleAction(
              icon: Icons.delete_rounded,
              onTap: onRemove,
              size: 18,
            ),
          ),
      ],
    );
  }
}

/// Brightness, contrast, saturation.
class _AdjustPanel extends StatelessWidget {
  const _AdjustPanel({
    required this.value,
    required this.t,
    required this.onChanged,
    required this.onCommitted,
  });

  final PhotoAdjust value;
  final AppLocalizations t;
  final void Function(PhotoAdjust) onChanged;
  final void Function(PhotoAdjust) onCommitted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: FloatingGlass(
        borderRadius: 22,
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _slider(
              t.editorAdjustBrightness,
              value.brightness,
              (v) => value.copyWith(brightness: v),
            ),
            _slider(
              t.editorAdjustContrast,
              value.contrast,
              (v) => value.copyWith(contrast: v),
            ),
            _slider(
              t.editorAdjustSaturation,
              value.saturation,
              (v) => value.copyWith(saturation: v),
            ),
          ],
        ),
      ),
    );
  }

  Widget _slider(String label, double v, PhotoAdjust Function(double) build) {
    return Row(
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
          ),
        ),
        Expanded(
          child: Slider(
            value: v,
            min: -1,
            max: 1,
            // Dragged live, committed once. Sixty snapshots of one slide would
            // take sixty taps to undo.
            onChanged: (x) => onChanged(build(x)),
            onChangeEnd: (x) => onCommitted(build(x)),
          ),
        ),
      ],
    );
  }
}

/// Levelling, shapes, turning and flipping. The frame itself is dragged on the
/// picture.
class _CropPanel extends StatelessWidget {
  const _CropPanel({
    required this.value,
    required this.ratio,
    required this.onRatio,
    required this.onChanged,
    required this.onTilt,
    required this.onTiltEnd,
  });

  final PhotoCrop value;
  final double? ratio;
  final void Function(double?) onRatio;
  final void Function(PhotoCrop) onChanged;
  final void Function(double) onTilt;
  final void Function(double) onTiltEnd;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final degrees = value.tilt * 180 / math.pi;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: FloatingGlass(
        borderRadius: 22,
        padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 44,
                  child: Text(
                    // One decimal: a horizon is out by fractions of a degree
                    // and a whole-number readout would sit on 0 through the
                    // whole first part of the drag.
                    '${degrees >= 0 ? '+' : ''}${degrees.toStringAsFixed(1)}°',
                    style: TextStyle(
                      color: value.tilt == 0
                          ? AppColors.textOnGlassDim
                          : AppColors.brandPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: value.tilt.clamp(-PhotoCrop.maxTilt, PhotoCrop.maxTilt),
                    min: -PhotoCrop.maxTilt,
                    max: PhotoCrop.maxTilt,
                    onChanged: onTilt,
                    onChangeEnd: onTiltEnd,
                  ),
                ),
                // Back to level in one tap. Finding zero again by dragging a
                // slider whose whole range is thirty degrees is a job.
                Tooltip(
                  message: t.editorLevel,
                  child: _CircleAction(
                    icon: Icons.straighten_rounded,
                    onTap: value.tilt == 0 ? null : () => onTiltEnd(0),
                    size: 18,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
            Tooltip(
              message: t.editorCropFree,
              child: _CircleAction(
                icon: Icons.crop_free_rounded,
                onTap: () => onRatio(null),
                filled: ratio == null,
                size: 20,
              ),
            ),
            _CircleAction(
              icon: Icons.crop_square_rounded,
              onTap: () => onRatio(1),
              filled: ratio == 1,
              size: 20,
            ),
            _CircleAction(
              icon: Icons.crop_portrait_rounded,
              onTap: () => onRatio(4 / 5),
              filled: ratio == 4 / 5,
              size: 20,
            ),
            _CircleAction(
              icon: Icons.crop_16_9_rounded,
              onTap: () => onRatio(16 / 9),
              filled: ratio == 16 / 9,
              size: 20,
            ),
            _CircleAction(
              icon: Icons.rotate_90_degrees_ccw_rounded,
              onTap: () => onChanged(
                value.copyWith(quarterTurns: value.quarterTurns - 1),
              ),
              size: 20,
            ),
            _CircleAction(
              icon: Icons.flip_rounded,
              onTap: () => onChanged(value.copyWith(flipped: !value.flipped)),
              filled: value.flipped,
              size: 20,
            ),
                _CircleAction(
                  icon: Icons.restore_rounded,
                  onTap: () => onChanged(PhotoCrop.none),
                  size: 20,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
