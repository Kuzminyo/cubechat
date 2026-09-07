import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import '../../../core/util/debug_log.dart';
import '../../../core/util/media_storage.dart';
import 'sticker_pack.dart';

/// The pack every install starts with, made real on disk when one is picked.
///
/// A library that begins empty is a picker that begins empty, and "keep a
/// picture from a chat and it will appear here" is a chicken-and-egg answer:
/// the first sticker anyone sends has to come from somewhere.
///
/// **What changed.** This used to *paint* its pack: a list of Unicode glyphs,
/// each rendered by the system emoji font into a transparent PNG the first time
/// it was picked. Nothing was bundled, which kept the APK where it was, and
/// what it produced was a big emoji rather than a sticker. There is artwork now
/// — see [StickerPack] — so the pack is bundled and this copies a file instead
/// of drawing one.
///
/// Everything after that is unchanged, and deliberately so: the copy lands in
/// the same directory the kept stickers use, and from that moment it is a file
/// like any other. It sends down the same media path, it draws in the same
/// bubble, and a build that has never heard of this pack still shows what it
/// receives.
///
/// The animation is what gets copied, not the still. A sticker that arrives
/// somewhere and does not move is not the sticker that was sent, and the
/// picture is what travels — there is no sticker server to look a name up in,
/// and an older build on the other phone has never heard of these names.
abstract final class BuiltinStickers {
  /// Where the copies live. The same directory the kept ones use: a sticker is
  /// a sticker whether it was saved or shipped, and one folder means one place
  /// for the path repair on iOS to find them again.
  static const String _folder = 'cubechat-stickers';

  /// The pack, in the order the picker shows it.
  static const List<String> names = StickerPack.all;

  /// What a sticker is called — the emoji shown where a picture cannot be, in
  /// a chat row or a reply quote.
  static String? emojiFor(String name) => StickerPack.glyphFor[name];

  /// The file a pack sticker is copied into, whether or not it exists yet.
  static Future<File> _fileFor(String name) async {
    final dir = await mediaDirectory(_folder);
    return File('${dir.path}${Platform.pathSeparator}builtin-$name.webp');
  }

  /// Copy [name] out of the bundle if it is not on disk yet, and hand back its
  /// path.
  ///
  /// Cheap on the second call and after a restart — the file is the cache, and
  /// it is checked before anything is read. Null when the copy failed, which
  /// the caller reports rather than sending a sticker that is not there.
  static Future<String?> materialize(String name) async {
    try {
      final file = await _fileFor(name);
      if (await file.exists() && await file.length() > 0) return file.path;
      final data = await rootBundle.load(StickerPack.animation(name));
      await file.writeAsBytes(data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      ));
      MediaPaths.forget(file.path);
      return file.path;
    } catch (e) {
      DebugLog.instance.log('STICKER', 'builtin "$name" failed: $e');
      return null;
    }
  }
}
