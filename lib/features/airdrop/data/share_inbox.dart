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

/// Whether [file] goes as a photo rather than as a file.
bool isPicture(SharedFile file) => file.mime.toLowerCase().startsWith('image/');

/// Everything one share brought: the files, and the text that came with them
/// or instead of them — a link from a browser is text and nothing else.
@immutable
class SharedBundle {
  const SharedBundle({this.files = const [], this.text});

  factory SharedBundle.fromPlatform({
    required Object? files,
    required Object? text,
  }) {
    final trimmed = text is String ? text.trim() : '';
    return SharedBundle(
      files: parseSharedFiles(files),
      text: trimmed.isEmpty ? null : trimmed,
    );
  }

  final List<SharedFile> files;
  final String? text;

  bool get isEmpty => files.isEmpty && text == null;

  /// Rooms carry text and pictures but no files.
  bool get roomsCanTakeAll => files.every(isPicture);
}

/// Android's "Share → CubeChat". See `MainActivity.shareFromIntent`.
abstract final class ShareInbox {
  static const MethodChannel _channel = MethodChannel('cubechat/share');

  static Future<SharedBundle> take() async {
    try {
      final files = await _channel.invokeMethod<Object?>('takeShared');
      Object? text;
      try {
        text = await _channel.invokeMethod<Object?>('takeSharedText');
      } on MissingPluginException {
        text = null;
      }
      return SharedBundle.fromPlatform(files: files, text: text);
    } catch (_) {
      return const SharedBundle();
    }
  }

  /// [onShare] for what is already waiting (a cold start from the share
  /// sheet), and again for every share while the app runs.
  static void listen(void Function(SharedBundle) onShare) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'shared') return;
      final bundle = await take();
      if (!bundle.isEmpty) onShare(bundle);
    });
    unawaited(
      take().then((bundle) {
        if (!bundle.isEmpty) onShare(bundle);
      }),
    );
  }
}
