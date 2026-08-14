import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../../core/util/debug_log.dart';
import '../../../core/util/media_storage.dart';

/// The pack every install starts with.
///
/// A library that begins empty is a picker that begins empty, and "keep a
/// picture from a chat and it will appear here" is a chicken-and-egg answer:
/// the first sticker anyone sends has to come from somewhere, and on a fresh
/// phone there is nowhere for it to come from.
///
/// There is still no sticker *server* — this pack is **drawn**, not shipped.
/// Each entry is an emoji painted onto a transparent square the first time it
/// is picked, written next to the kept stickers as an ordinary PNG, and from
/// that moment on it is a file like any other: it sends down the same path, it
/// renders in the same bubble, and a build that has never heard of this list
/// still shows it. Nothing is bundled, so the APK does not grow, and nothing is
/// fetched, so it works with the radio off.
abstract final class BuiltinStickers {
  /// The side of the rendered square, in pixels.
  ///
  /// Big enough that the bubble (148 pt) and the picker cell draw it without
  /// softening on a 3× screen, small enough that the PNG stays a few tens of
  /// kilobytes — which is what has to cross the mesh when one is sent.
  static const int renderSize = 320;

  /// Where the drawn ones live. The same directory the kept ones use: a
  /// sticker is a sticker whether it was saved or drawn, and one folder means
  /// one place for the path repair on iOS to find them again.
  static const String _folder = 'cubechat-stickers';

  /// The pack itself, in the order it is shown.
  ///
  /// Ordinary, widely-drawn emoji only. Anything newer than about Emoji 12
  /// risks landing on a phone whose system font has never heard of it, and a
  /// sticker that renders as a blank box is worse than one that isn't offered.
  static const List<String> glyphs = <String>[
    '😀', '😂', '🥲', '😍', '😎', '🤩', '🥳', '😭',
    '😡', '🤯', '🤔', '🤗', '🙃', '😴', '🤤', '🥴',
    '🤒', '🥶', '🤠', '🤫', '😇', '🤪', '😱', '🫠',
    '👍', '👎', '👏', '🙏', '💪', '🤝', '✌️', '👋',
    '❤️', '💔', '💕', '🔥', '✨', '⭐', '💯', '🎉',
    '🎁', '☕', '🍕', '🌚', '🌈', '⚡', '🐱', '🐶',
  ];

  /// The file a glyph is drawn into, whether or not it exists yet.
  static Future<File> _fileFor(String glyph) async {
    final dir = await mediaDirectory(_folder);
    // Named by codepoint rather than by the character itself: the glyph is not
    // a filename on every filesystem, and a variation selector is invisible in
    // one but decisive in the other.
    final name = glyph.runes
        .map((r) => r.toRadixString(16).padLeft(4, '0'))
        .join('-');
    return File('${dir.path}${Platform.pathSeparator}builtin-$name.png');
  }

  /// Draw [glyph] if it has not been drawn before and hand back its path.
  ///
  /// Cheap on the second call and after a restart — the file is the cache, and
  /// it is checked before anything is painted. Null when the paint failed,
  /// which the caller reports rather than sending a sticker that is not there.
  static Future<String?> materialize(String glyph) async {
    try {
      final file = await _fileFor(glyph);
      if (await file.exists() && await file.length() > 0) return file.path;
      final bytes = await _paint(glyph);
      if (bytes == null) return null;
      await file.writeAsBytes(bytes);
      MediaPaths.forget(file.path);
      return file.path;
    } catch (e) {
      DebugLog.instance.log('STICKER', 'builtin "$glyph" failed: $e');
      return null;
    }
  }

  /// The emoji, centred on a transparent square, as PNG bytes.
  ///
  /// No font family is named on purpose: leaving it to the engine's fallback
  /// chain is what reaches the system's colour emoji font, on both platforms,
  /// without this app carrying one.
  static Future<Uint8List?> _paint(String glyph) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final painter = TextPainter(
      text: TextSpan(
        text: glyph,
        style: const TextStyle(fontSize: renderSize * 0.78),
      ),
      textDirection: TextDirection.ltr,
      // The device's font scale must not reach this: a sticker drawn at 1.3×
      // on one phone and 1.0× on another is a different picture, and the
      // square it is drawn into is fixed.
      textScaler: TextScaler.noScaling,
    )..layout();
    painter.paint(
      canvas,
      Offset(
        (renderSize - painter.width) / 2,
        (renderSize - painter.height) / 2,
      ),
    );
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(renderSize, renderSize);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data?.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
    }
  }
}
