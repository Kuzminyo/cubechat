import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import '../../../../core/routing/page_transitions.dart';

const SystemUiOverlayStyle _editorOverlayStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.black,
  systemNavigationBarColor: Colors.black,
  statusBarIconBrightness: Brightness.light,
  systemNavigationBarIconBrightness: Brightness.light,
);
const ProImageEditorConfigs _editorConfigs = ProImageEditorConfigs(
  mainEditor: MainEditorConfigs(
    icons: MainEditorIcons(
      closeEditor: Icons.close_rounded,
      doneIcon: Icons.check_rounded,
      applyChanges: Icons.check_rounded,
      backButton: Icons.arrow_back_rounded,
      undoAction: Icons.undo_rounded,
      redoAction: Icons.redo_rounded,
      removeElementZone: Icons.delete_outline_rounded,
    ),
  ),
  paintEditor: PaintEditorConfigs(
    icons: PaintEditorIcons(
      bottomNavBar: Icons.brush_rounded,
      moveAndZoom: Icons.open_with_rounded,
      changeOpacity: Icons.opacity_rounded,
      // A mop, which is odd, but this Flutter has no eraser glyph — neither
      // `ink_eraser` nor its rounded twin exist here — and "wipe it away" is
      // at least the right verb.
      eraser: Icons.cleaning_services_rounded,
      lineWeight: Icons.line_weight_rounded,
      freeStyle: Icons.edit_rounded,
      freeStyleArrowStart: Icons.edit_rounded,
      freeStyleArrowEnd: Icons.edit_rounded,
      freeStyleArrowStartEnd: Icons.edit_rounded,
      arrow: Icons.arrow_right_alt_rounded,
      line: Icons.horizontal_rule_rounded,
      fill: Icons.format_color_fill_rounded,
      noFill: Icons.format_color_reset_rounded,
      rectangle: Icons.crop_free_rounded,
      // Outline, not a filled disc: these are shapes you draw, and every other
      // one in this row — rectangle, hexagon, polygon — is drawn as an outline.
      // A solid circle among them looked like a colour swatch.
      circle: Icons.circle_outlined,
      dashLine: Icons.power_input_rounded,
      dashDotLine: Icons.linear_scale_rounded,
      hexagon: Icons.hexagon_rounded,
      polygon: Icons.pentagon_rounded,
      pixelate: Icons.grid_on_rounded,
      blur: Icons.blur_on_rounded,
      applyChanges: Icons.check_rounded,
      backButton: Icons.arrow_back_rounded,
      undoAction: Icons.undo_rounded,
      redoAction: Icons.redo_rounded,
    ),
  ),
  textEditor: TextEditorConfigs(
    icons: TextEditorIcons(
      bottomNavBar: Icons.title_rounded,
      fontScale: Icons.format_size_rounded,
      resetFontScale: Icons.refresh_rounded,
      backgroundMode: Icons.layers_rounded,
      backButton: Icons.arrow_back_rounded,
      applyChanges: Icons.check_rounded,
    ),
  ),
  cropRotateEditor: CropRotateEditorConfigs(
    icons: CropRotateEditorIcons(
      bottomNavBar: Icons.crop_rotate_rounded,
      rotate: Icons.rotate_90_degrees_ccw_rounded,
      aspectRatio: Icons.crop_rounded,
      flip: Icons.flip_rounded,
      reset: Icons.restore_rounded,
      applyChanges: Icons.check_rounded,
      backButton: Icons.arrow_back_rounded,
      undoAction: Icons.undo_rounded,
      redoAction: Icons.redo_rounded,
    ),
  ),
  tuneEditor: TuneEditorConfigs(
    icons: TuneEditorIcons(
      bottomNavBar: Icons.tune_rounded,
      brightness: Icons.brightness_6_rounded,
      contrast: Icons.contrast_rounded,
      // A water drop reads as "blur" or "opacity" everywhere else in this same
      // editor. Not a palette either — `hue` below already is one, and two
      // identical glyphs side by side is worse than one imprecise glyph.
      saturation: Icons.invert_colors_rounded,
      exposure: Icons.exposure_rounded,
      hue: Icons.palette_rounded,
      temperature: Icons.thermostat_rounded,
      sharpness: Icons.shutter_speed_rounded,
      fade: Icons.blur_off_rounded,
      luminance: Icons.light_mode_rounded,
      applyChanges: Icons.check_rounded,
      backButton: Icons.arrow_back_rounded,
      undoAction: Icons.undo_rounded,
      redoAction: Icons.redo_rounded,
    ),
  ),
  filterEditor: FilterEditorConfigs(
    icons: FilterEditorIcons(
      // Not `filter_alt`, which is a funnel — the icon every list in every app
      // uses for narrowing rows down. Here "filter" means the other thing
      // entirely, and `photo_filter` is Material's own glyph for it: a frame
      // with a sparkle, the same shape Instagram and Telegram settled on.
      bottomNavBar: Icons.photo_filter_rounded,
      applyChanges: Icons.check_rounded,
      backButton: Icons.arrow_back_rounded,
    ),
  ),
  blurEditor: BlurEditorConfigs(
    icons: BlurEditorIcons(
      bottomNavBar: Icons.blur_on_rounded,
      applyChanges: Icons.check_rounded,
      backButton: Icons.arrow_back_rounded,
    ),
  ),
  emojiEditor: EmojiEditorConfigs(
    icons: EmojiEditorIcons(
      bottomNavBar: Icons.sentiment_satisfied_alt_rounded,
    ),
  ),
  stickerEditor: StickerEditorConfigs(
    icons: StickerEditorIcons(
      bottomNavBar: Icons.image_rounded,
    ),
  ),
  layerInteraction: LayerInteractionConfigs(
    icons: LayerInteractionIcons(
      remove: Icons.close_rounded,
      edit: Icons.edit_rounded,
      rotateScale: Icons.sync_rounded,
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
