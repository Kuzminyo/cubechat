import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/routing/page_transitions.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

/// Open the full-screen image editor on [source] and return the edited JPEG
/// bytes, or null if the user backed out without confirming.
///
/// This is the Telegram-style "preview then send" step: the editor *is* the
/// preview — it shows the photo full-screen with the paint (pen / marker),
/// text, crop, filter and sticker tools, and its confirm (✓) is what "sends".
/// So a caller opens it after a camera capture or a single gallery pick, and
/// sends whatever comes back.
///
/// Wiring detail: pro_image_editor fires [ProImageEditorCallbacks.onCloseEditor]
/// on both confirm and cancel, but [ProImageEditorCallbacks.onImageEditingComplete]
/// only on confirm — so the completed bytes are stashed there and the route is
/// popped from onCloseEditor, leaving `edited` non-null only when the user
/// actually confirmed.
Future<Uint8List?> openImageEditor(
  BuildContext context,
  Uint8List source,
) async {
  Uint8List? edited;
  await Navigator.of(context).push<void>(
    mediaRoute<void>(
      (routeContext) => ProImageEditor.memory(
        source,
        callbacks: ProImageEditorCallbacks(
          onImageEditingComplete: (bytes) async {
            edited = bytes;
          },
          // Only ever called with EditorMode.main (sub-editors have their own
          // callbacks), so an unconditional pop is correct here.
          onCloseEditor: (_) => Navigator.of(routeContext).pop(),
        ),
      ),
    ),
  );
  return edited;
}
