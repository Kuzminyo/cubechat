import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'image_editor.dart';

Future<Uint8List?> openStickerEditor(
  BuildContext context,
  Uint8List source,
) {
  return openImageEditor(context, source);
}
