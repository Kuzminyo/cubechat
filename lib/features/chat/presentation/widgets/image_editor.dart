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
