import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/routing/page_transitions.dart';
import '../editor/photo_editor_screen.dart';

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
/// preview — it shows the photo full-screen with the draw, crop and adjust
/// tools, and its confirm is what "sends". So a caller opens it after a camera
/// capture or a single gallery pick, and sends whatever comes back.
///
/// ## Why this is ours now
///
/// It was `pro_image_editor` — 579 files and 152,000 lines, BSD-3, to own for
/// three tools. What forced the decision was not the size but a wall: its
/// paint editor exposes no hook for a bottom bar, only close buttons, sliders
/// and a colour picker. The draw / sticker / text tabs that were asked for
/// could not be put there at all, at any effort short of forking the package
/// and maintaining it.
///
/// What replaced it is smaller than the fork would have been and is entirely
/// ours: one immutable `PhotoEdit` value, one painter shared by the preview
/// and the export — so what is encoded is literally what was approved — and a
/// history that is a stack of those values rather than a set of inverse
/// operations each new tool has to implement correctly.
///
/// The contract is unchanged, which is what let the swap be one file: five
/// callers, all `openImageEditor(context, bytes) -> bytes?`.
Future<Uint8List?> openImageEditor(
  BuildContext context,
  Uint8List source,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  // System bars away for the duration: the app runs edge-to-edge and a
  // full-screen photo editor without a status bar is what every other one
  // looks like.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setSystemUIOverlayStyle(_editorOverlayStyle);
  try {
    // Root navigator, not the one in scope.
    //
    // Opened from the Profile tab — which is where you land with no avatar
    // yet, by tapping the empty circle — `Navigator.of(context)` resolves to
    // that *branch’s* navigator, so the editor was pushed inside the shell and
    // the app’s own floating nav bar stayed on top of it. Going through
    // AvatarScreen instead (the path you get once a picture exists) pushes
    // from a root route, which is why it only ever reproduced from a clean
    // start with no avatar at all.
    return await navigator.push<Uint8List>(
      mediaRoute<Uint8List>(
        (_) => AnnotatedRegion<SystemUiOverlayStyle>(
          value: _editorOverlayStyle,
          child: PhotoEditorScreen(source: source),
        ),
      ),
    );
  } finally {
    // Restored whatever happened on the way out — backing out of the editor
    // must not leave the rest of the app without its system bars.
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
}
