import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/widgets/floating_glass.dart';
import '../../../../l10n/app_localizations.dart';
import 'photo_edit_model.dart';
import 'photo_edit_render.dart';

/// Which island is open. `none` is the picture with nothing over it.
enum EditorTool { none, crop, draw, adjust }

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
  ui.Image? _image;
  EditorTool _tool = EditorTool.none;
  bool _busy = false;

  // Draw settings, which are not part of the edit: changing the pen colour is
  // not something to undo.
  Color _penColor = const Color(0xFFFFCC00);
  double _penWidth = 14;
  bool _erasing = false;

  /// The stroke being drawn right now, kept out of the history until the
  /// finger lifts — otherwise every pointer move would be an undo step.
  Stroke? _live;

  @override
  void initState() {
    super.initState();
    _history.addListener(_onEdit);
    _load();
  }

  @override
  void dispose() {
    _history.removeListener(_onEdit);
    _image?.dispose();
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

  // ---- drawing ------------------------------------------------------------

  void _startStroke(Offset image) {
    setState(() {
      _live = Stroke(
        points: <Offset>[image],
        color: _penColor,
        width: _penWidth,
        erase: _erasing,
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
        erase: live.erase,
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

  // ---- done ---------------------------------------------------------------

  Future<void> _confirm() async {
    final image = _image;
    if (image == null || _busy) return;
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
        PhotoEditPainter(image: image, edit: _history.value),
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
                    Expanded(
                      child: _Canvas(
                        image: image,
                        edit: _edit,
                        drawing: _tool == EditorTool.draw,
                        onStart: _startStroke,
                        onMove: _extendStroke,
                        onEnd: _endStroke,
                      ),
                    ),
                    _panel(t),
                    _Island(
                      tool: _tool,
                      onPick: (tool) => setState(
                        () => _tool = _tool == tool ? EditorTool.none : tool,
                      ),
                      t: t,
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _panel(AppLocalizations t) {
    switch (_tool) {
      case EditorTool.none:
        return const SizedBox(height: 8);
      case EditorTool.draw:
        return _DrawPanel(
          color: _penColor,
          width: _penWidth,
          erasing: _erasing,
          onColor: (c) => setState(() {
            _penColor = c;
            _erasing = false;
          }),
          onWidth: (w) => setState(() => _penWidth = w),
          onErase: () => setState(() => _erasing = !_erasing),
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
          onChanged: (c) => _history.push(_history.value.copyWith(crop: c)),
        );
    }
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
          _CircleAction(icon: Symbols.arrow_back, onTap: onClose),
          const Spacer(),
          _CircleAction(
            icon: Symbols.undo,
            onTap: canUndo ? onUndo : null,
          ),
          const SizedBox(width: 8),
          _CircleAction(
            icon: Symbols.redo,
            onTap: canRedo ? onRedo : null,
          ),
          const SizedBox(width: 8),
          _CircleAction(
            icon: Symbols.check,
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
  });

  final IconData icon;
  final VoidCallback? onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: filled
          ? AppColors.brandPrimary.withValues(alpha: enabled ? 0.92 : 0.35)
          : Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(
            icon,
            size: 22,
            color: filled
                ? AppColors.bgDeep
                : Colors.white.withValues(alpha: enabled ? 1 : 0.35),
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
    required this.drawing,
    required this.onStart,
    required this.onMove,
    required this.onEnd,
  });

  final ui.Image image;
  final PhotoEdit edit;
  final bool drawing;
  final void Function(Offset image) onStart;
  final void Function(Offset image) onMove;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final painter = PhotoEditPainter(image: image, edit: edit);
    final out = painter.outputSize;
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        Offset map(Offset local) => toImageSpace(local, box, out);
        return GestureDetector(
          onPanStart: drawing ? (d) => onStart(map(d.localPosition)) : null,
          onPanUpdate: drawing ? (d) => onMove(map(d.localPosition)) : null,
          onPanEnd: drawing ? (_) => onEnd() : null,
          child: CustomPaint(
            size: box,
            painter: _EditPainter(painter),
            isComplex: true,
          ),
        );
      },
    );
  }
}

class _EditPainter extends CustomPainter {
  const _EditPainter(this.edit);

  final PhotoEditPainter edit;

  @override
  void paint(Canvas canvas, Size size) {
    final out = edit.outputSize;
    if (out.isEmpty) return;
    final scale = (size.width / out.width) < (size.height / out.height)
        ? size.width / out.width
        : size.height / out.height;
    canvas.save();
    canvas.translate(
      (size.width - out.width * scale) / 2,
      (size.height - out.height * scale) / 2,
    );
    canvas.scale(scale);
    edit.paint(canvas);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_EditPainter old) =>
      !identical(old.edit.edit, edit.edit) ||
      !identical(old.edit.image, edit.image);
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
                icon: Symbols.crop_rotate,
                tooltip: t.editorToolCrop,
                active: tool == EditorTool.crop,
                onTap: () => onPick(EditorTool.crop),
              ),
              _IslandTool(
                icon: Symbols.brush,
                tooltip: t.editorToolDraw,
                active: tool == EditorTool.draw,
                onTap: () => onPick(EditorTool.draw),
              ),
              _IslandTool(
                icon: Symbols.tune,
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
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Icon(
              icon,
              size: 26,
              color: active ? AppColors.brandPrimary : AppColors.textOnGlass,
            ),
          ),
        ),
      ),
    );
  }
}

/// Colours, thickness and the eraser.
class _DrawPanel extends StatelessWidget {
  const _DrawPanel({
    required this.color,
    required this.width,
    required this.erasing,
    required this.onColor,
    required this.onWidth,
    required this.onErase,
  });

  final Color color;
  final double width;
  final bool erasing;
  final void Function(Color) onColor;
  final void Function(double) onWidth;
  final VoidCallback onErase;

  /// Enough to mark a photograph and no more. A full picker is a second screen
  /// for a decision nobody agonises over — these are the colours that stay
  /// legible on both a bright sky and a dark road.
  static const _palette = <Color>[
    Color(0xFFFFCC00),
    Color(0xFFFF3B30),
    Color(0xFF34C759),
    Color(0xFF0A84FF),
    Color(0xFFFFFFFF),
    Color(0xFF000000),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: FloatingGlass(
        borderRadius: 22,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                for (final c in _palette)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: GestureDetector(
                      onTap: () => onColor(c),
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: !erasing && c == color
                                ? AppColors.brandPrimary
                                : Colors.white24,
                            width: !erasing && c == color ? 3 : 1,
                          ),
                        ),
                      ),
                    ),
                  ),
                const Spacer(),
                _CircleAction(
                  icon: Symbols.ink_eraser,
                  onTap: onErase,
                  filled: erasing,
                ),
              ],
            ),
            Row(
              children: [
                const Icon(Symbols.line_weight,
                    size: 18, color: Colors.white54),
                Expanded(
                  child: Slider(
                    value: width,
                    min: 4,
                    max: 48,
                    onChanged: onWidth,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
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
            _slider(t.editorAdjustBrightness, value.brightness,
                (v) => value.copyWith(brightness: v)),
            _slider(t.editorAdjustContrast, value.contrast,
                (v) => value.copyWith(contrast: v)),
            _slider(t.editorAdjustSaturation, value.saturation,
                (v) => value.copyWith(saturation: v)),
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

/// Turning and flipping. The frame itself is dragged on the picture.
class _CropPanel extends StatelessWidget {
  const _CropPanel({required this.value, required this.onChanged});

  final PhotoCrop value;
  final void Function(PhotoCrop) onChanged;

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
              _CircleAction(
                icon: Symbols.rotate_90_degrees_ccw,
                onTap: () => onChanged(
                  value.copyWith(quarterTurns: value.quarterTurns - 1),
                ),
              ),
              const SizedBox(width: 10),
              _CircleAction(
                icon: Symbols.flip,
                onTap: () => onChanged(value.copyWith(flipped: !value.flipped)),
                filled: value.flipped,
              ),
              const SizedBox(width: 10),
              _CircleAction(
                icon: Symbols.restore,
                onTap: () => onChanged(PhotoCrop.none),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
