import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import '../../../../core/routing/page_transitions.dart';
import '../../../../core/theme/colors.dart';
import '../../../../core/widgets/floating_glass.dart';
import '../../../../l10n/app_localizations.dart';

const SystemUiOverlayStyle _editorOverlayStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.black,
  systemNavigationBarColor: Colors.black,
  statusBarIconBrightness: Brightness.light,
  systemNavigationBarIconBrightness: Brightness.light,
);
/// The tool row, as an island on the app's own glass.
///
/// The package draws a plain bar bolted to the bottom edge, which is the one
/// shape this interface does not have anywhere else — the nav bar, the chat
/// header and the composer are all floating panes. Asked for as "сделай в
/// остров так же само как и наш главный бар".
///
/// Built rather than themed because a colour cannot make a bar into an island:
/// it needs its own inset, radius and fill. The five tools are the package's
/// own public methods, so nothing here reimplements an editor — this is the
/// row that calls them.
ReactiveWidget _islandBottomBar(
  ProImageEditorState editor,
  Stream<void> rebuild,
  Key key,
) {
  return ReactiveWidget(
    stream: rebuild,
    key: key,
    builder: (context) {
      final t = AppLocalizations.of(context);
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          // Hugging its three icons and centred, the way the reference pill
          // does — a bar stretched edge to edge is the shape this replaces.
          child: Center(
            child: FloatingGlass(
          borderRadius: 26,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Three, in this order, and no words: crop the frame, draw on
              // it, adjust it. The reference row this copies has a fourth —
              // "HD" — which was asked to be left out.
              _EditorTool(
                icon: Symbols.crop_rotate,
                tooltip: t.editorToolCrop,
                onTap: editor.openCropRotateEditor,
              ),
              _EditorTool(
                icon: Symbols.brush,
                tooltip: t.editorToolDraw,
                onTap: editor.openPaintEditor,
              ),
              _EditorTool(
                icon: Symbols.tune,
                tooltip: t.editorToolAdjust,
                onTap: editor.openTuneEditor,
              ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// One tool in the island: the glyph alone, generously spaced.
///
/// No caption. Three icons a person can hit without reading is the shape the
/// reference has, and a word under each turns a row of controls into a row of
/// labels — which is what the send screen's top bar was just cured of.
class _EditorTool extends StatelessWidget {
  const _EditorTool({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          // Wide enough that three of them read as a row rather than a cluster,
          // and that a thumb lands on one of them and not between two.
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Icon(icon, size: 26, color: AppColors.textOnGlass),
        ),
      ),
    );
  }
}

/// Built on each open rather than held as a `const`.
///
/// [AppColors] is a class of mutable statics that the theme controller
/// rewrites when a palette is chosen — that is how a palette retints the
/// interface rather than only its accents — so a `const` config would freeze
/// whatever colours happened to be loaded when this library was first touched.
ProImageEditorConfigs get _editorConfigs => ProImageEditorConfigs(
  mainEditor: MainEditorConfigs(
    // The island above replaces the package's own bar; the rest of the chrome
    // takes the app's colours so the editor stops looking like a different
    // application opened on top of this one.
    widgets: MainEditorWidgets(bottomBar: _islandBottomBar),
    style: MainEditorStyle(
      background: AppColors.bgDeep,
      appBarBackground: Colors.transparent,
      appBarColor: AppColors.textOnGlass,
      bottomBarBackground: Colors.transparent,
      bottomBarColor: AppColors.brandPrimary,
    ),
    icons: MainEditorIcons(
      closeEditor: Symbols.close,
      doneIcon: Symbols.check,
      applyChanges: Symbols.check,
      backButton: Symbols.arrow_back,
      undoAction: Symbols.undo,
      redoAction: Symbols.redo,
      removeElementZone: Symbols.delete_outline,
    ),
  ),
  paintEditor: PaintEditorConfigs(
    icons: PaintEditorIcons(
      bottomNavBar: Symbols.brush,
      moveAndZoom: Symbols.open_with,
      changeOpacity: Symbols.opacity,
      // An actual eraser at last. The note here said "a mop, which is odd,
      // but this Flutter has no eraser glyph — neither `ink_eraser` nor its
      // rounded twin exist here". True of Material Icons and not of Material
      // Symbols, which this file now draws from.
      eraser: Symbols.ink_eraser,
      lineWeight: Symbols.line_weight,
      freeStyle: Symbols.edit,
      freeStyleArrowStart: Symbols.edit,
      freeStyleArrowEnd: Symbols.edit,
      freeStyleArrowStartEnd: Symbols.edit,
      arrow: Symbols.arrow_right_alt,
      line: Symbols.horizontal_rule,
      fill: Symbols.format_color_fill,
      noFill: Symbols.format_color_reset,
      rectangle: Symbols.crop_free,
      // Outline, not a filled disc: these are shapes you draw, and every other
      // one in this row — rectangle, hexagon, polygon — is drawn as an outline.
      // A solid circle among them looked like a colour swatch.
      circle: Symbols.circle,
      dashLine: Symbols.power_input,
      dashDotLine: Symbols.linear_scale,
      hexagon: Symbols.hexagon,
      polygon: Symbols.pentagon,
      pixelate: Symbols.grid_on,
      blur: Symbols.blur_on,
      applyChanges: Symbols.check,
      backButton: Symbols.arrow_back,
      undoAction: Symbols.undo,
      redoAction: Symbols.redo,
    ),
  ),
  textEditor: TextEditorConfigs(
    icons: TextEditorIcons(
      bottomNavBar: Symbols.title,
      fontScale: Symbols.format_size,
      resetFontScale: Symbols.refresh,
      backgroundMode: Symbols.layers,
      backButton: Symbols.arrow_back,
      applyChanges: Symbols.check,
    ),
  ),
  cropRotateEditor: CropRotateEditorConfigs(
    icons: CropRotateEditorIcons(
      bottomNavBar: Symbols.crop_rotate,
      rotate: Symbols.rotate_90_degrees_ccw,
      aspectRatio: Symbols.crop,
      flip: Symbols.flip,
      reset: Symbols.restore,
      applyChanges: Symbols.check,
      backButton: Symbols.arrow_back,
      undoAction: Symbols.undo,
      redoAction: Symbols.redo,
    ),
  ),
  tuneEditor: TuneEditorConfigs(
    icons: TuneEditorIcons(
      bottomNavBar: Symbols.tune,
      brightness: Symbols.brightness_6,
      contrast: Symbols.contrast,
      // A water drop reads as "blur" or "opacity" everywhere else in this same
      // editor. Not a palette either — `hue` below already is one, and two
      // identical glyphs side by side is worse than one imprecise glyph.
      saturation: Symbols.invert_colors,
      exposure: Symbols.exposure,
      hue: Symbols.palette,
      temperature: Symbols.thermostat,
      sharpness: Symbols.shutter_speed,
      fade: Symbols.blur_off,
      luminance: Symbols.light_mode,
      applyChanges: Symbols.check,
      backButton: Symbols.arrow_back,
      undoAction: Symbols.undo,
      redoAction: Symbols.redo,
    ),
  ),
  filterEditor: FilterEditorConfigs(
    icons: FilterEditorIcons(
      // Not `filter_alt`, which is a funnel — the icon every list in every app
      // uses for narrowing rows down. Here "filter" means the other thing
      // entirely, and `photo_filter` is Material's own glyph for it: a frame
      // with a sparkle, the same shape Instagram and Telegram settled on.
      bottomNavBar: Symbols.photo_filter,
      applyChanges: Symbols.check,
      backButton: Symbols.arrow_back,
    ),
  ),
  blurEditor: BlurEditorConfigs(
    icons: BlurEditorIcons(
      bottomNavBar: Symbols.blur_on,
      applyChanges: Symbols.check,
      backButton: Symbols.arrow_back,
    ),
  ),
  emojiEditor: EmojiEditorConfigs(
    icons: EmojiEditorIcons(
      bottomNavBar: Symbols.sentiment_satisfied_alt,
    ),
  ),
  stickerEditor: StickerEditorConfigs(
    icons: StickerEditorIcons(
      bottomNavBar: Symbols.image,
    ),
  ),
  layerInteraction: LayerInteractionConfigs(
    icons: LayerInteractionIcons(
      remove: Symbols.close,
      edit: Symbols.edit,
      rotateScale: Symbols.sync,
    ),
  ),
);

/// Open the full-screen image editor on [source] and return the edited JPEG
/// bytes, or null if the user backed out without confirming.
///
/// This is the Telegram-style "preview then send" step: the editor *is* the
/// preview - it shows the photo full-screen with the paint (pen / marker),
/// text, crop, filter and sticker tools, and its confirm is what "sends".
/// So a caller opens it after a camera capture or a single gallery pick, and
/// sends whatever comes back.
///
/// Wiring detail: pro_image_editor fires [ProImageEditorCallbacks.onCloseEditor]
/// on both confirm and cancel, but [ProImageEditorCallbacks.onImageEditingComplete]
/// only on confirm - so the completed bytes are stashed there and the route is
/// popped from onCloseEditor, leaving `edited` non-null only when the user
/// actually confirmed.
Future<Uint8List?> openImageEditor(
  BuildContext context,
  Uint8List source,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  Uint8List? edited;
  // System bars away for the duration: the app runs edge-to-edge, and
  // pro_image_editor lays its own chrome against the physical edges rather
  // than inside the insets. A full-screen photo editor without a status bar is
  // what every other one looks like anyway.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setSystemUIOverlayStyle(_editorOverlayStyle);
  try {
    // Root navigator, not the one in scope.
    //
    // This is what was actually putting a bar across the tools. Opened from
    // the Profile tab - which is where you land with no avatar yet, by tapping
    // the empty circle - `Navigator.of(context)` resolves to that *branch's*
    // navigator, so the editor was pushed inside the shell and the app's own
    // floating nav bar stayed on top of it. Going through AvatarScreen instead
    // (the path you get once a picture exists) pushes from a root route, which
    // is why it only ever reproduced from a clean start with no avatar at all.
    await navigator.push<void>(
      mediaRoute<void>(
        (routeContext) => AnnotatedRegion<SystemUiOverlayStyle>(
          value: _editorOverlayStyle,
          child: SizedBox.expand(
            child: ColoredBox(
              color: Colors.black,
              child: ProImageEditor.memory(
                source,
                configs: _editorConfigs,
                callbacks: ProImageEditorCallbacks(
                  onImageEditingComplete: (bytes) async {
                    edited = bytes;
                  },
                  // Only ever called with EditorMode.main (sub-editors have
                  // their own callbacks), so an unconditional pop is correct.
                  onCloseEditor: (_) => Navigator.of(routeContext).pop(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  } finally {
    // Restored whatever happened on the way out - backing out of the editor
    // must not leave the rest of the app without its system bars.
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
  return edited;
}
