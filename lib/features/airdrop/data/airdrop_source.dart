import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/transport/inner_payload.dart' show safeFileName;
import '../../../core/utils/file_mime.dart';

/// A file on this phone, ready to be offered.
@immutable
class AirDropSource {
  const AirDropSource({
    required this.file,
    required this.name,
    required this.size,
    required this.mime,
  });

  final File file;
  final String name;
  final int size;
  final String mime;

  static Future<AirDropSource> fromFile(File file, {String? name}) async {
    final shown = safeFileName(name ?? file.uri.pathSegments.last);
    return AirDropSource(
      file: file,
      name: shown,
      size: await file.length(),
      mime: fileMimeType(shown),
    );
  }
}
