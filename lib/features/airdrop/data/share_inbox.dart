import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../core/transport/inner_payload.dart' show safeFileName;

/// A file another app handed to CubeChat through the system share sheet,
/// already copied into our cache by the platform side.
@immutable
class SharedFile {
  const SharedFile({
    required this.path,
    required this.name,
    required this.mime,
  });

  final String path;
  final String name;
  final String mime;
}

/// Rows as the platform sends them. The name came from another app and is
/// treated as such; a malformed row is dropped rather than trusted.
List<SharedFile> parseSharedFiles(Object? raw) {
  if (raw is! List) return const [];
  final out = <SharedFile>[];
  for (final row in raw) {
    if (row is! Map) continue;
    final path = row['path'];
    final name = row['name'];
    final mime = row['mime'];
    if (path is! String || name is! String) continue;
    out.add(
      SharedFile(
        path: path,
        name: safeFileName(name),
        mime: mime is String ? mime : 'application/octet-stream',
      ),
    );
  }
  return out;
}

/// Android's "Share → CubeChat". See `MainActivity.shareFromIntent`.
abstract final class ShareInbox {
  static const MethodChannel _channel = MethodChannel('cubechat/share');

  static Future<List<SharedFile>> take() async {
    try {
      return parseSharedFiles(
        await _channel.invokeMethod<Object?>('takeShared'),
      );
    } catch (_) {
      return const [];
    }
  }

  /// [onFiles] for what is already waiting (a cold start from the share
  /// sheet), and again for every share while the app runs.
  static void listen(void Function(List<SharedFile>) onFiles) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'shared') return;
      final files = await take();
      if (files.isNotEmpty) onFiles(files);
    });
    unawaited(
      take().then((files) {
        if (files.isNotEmpty) onFiles(files);
      }),
    );
  }
}
