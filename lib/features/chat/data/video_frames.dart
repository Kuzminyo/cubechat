import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/util/debug_log.dart';

/// A picture of a video before it plays: its first frame as a JPEG, and its
/// length.
typedef VideoPoster = ({String? frame, Duration? length, double? aspect});

/// The first frame and length of a video on this phone.
///
/// What a clip and a circle show in the chat before they are played. It
/// replaced a paused video player per bubble: a hardware decoder and a texture
/// each, opened as a clip scrolled into view, which is a heavy way to draw one
/// picture. See `VideoFramePlugin.kt`.
///
/// Cached twice: the answer in memory for this run, so a bubble rebuilt while
/// scrolling does not ask again, and the JPEG on disk under the cache
/// directory, so the next launch does not decode it again. The system may
/// clear that directory at any time; the frame is then simply made again.
class VideoFrames {
  VideoFrames._();

  static const _channel = MethodChannel('cubechat/video_frame');

  /// Big enough for the widest bubble on a dense screen, small enough that a
  /// chat full of clips is a few hundred kilobytes of JPEG.
  static const int maxSide = 720;

  static final Map<String, Future<VideoPoster>> _known = {};
  static final Map<String, VideoPoster> _ready = {};

  /// Already known this run, without waiting: lets a bubble draw its frame on
  /// its first build instead of flashing an empty box for one.
  static VideoPoster? peek(String videoPath) => _ready[videoPath];

  static Future<VideoPoster> of(String videoPath) =>
      _known[videoPath] ??= _make(videoPath);

  static const VideoPoster _none = (frame: null, length: null, aspect: null);

  static Future<VideoPoster> _make(String videoPath) async {
    try {
      final stat = await File(videoPath).stat();
      if (stat.type == FileSystemEntityType.notFound) return _forget(videoPath);
      final dir = await getTemporaryDirectory();
      // Named by the file, its size and its time, so a path reused for a
      // different video does not come back with the old picture.
      final name = _fnv('$videoPath|${stat.size}|'
          '${stat.modified.millisecondsSinceEpoch}');
      final out = '${dir.path}/video_frames/$name.jpg';
      final answer = await _channel.invokeMapMethod<String, Object?>('frame', {
        'path': videoPath,
        'out': out,
        'maxSide': maxSide,
      });
      if (answer == null) return _forget(videoPath);
      final ms = answer['durationMs'];
      final w = answer['width'];
      final h = answer['height'];
      final poster = (
        frame: answer['frame'] == true ? out : null,
        length: ms is num && ms > 0 ? Duration(milliseconds: ms.round()) : null,
        aspect: w is num && h is num && w > 0 && h > 0 ? w / h : null,
      );
      return _ready[videoPath] = poster;
    } on MissingPluginException {
      return _ready[videoPath] = _none;
    } catch (e) {
      DebugLog.instance.log('MEDIA', 'no first frame for a video: $e');
      return _forget(videoPath);
    }
  }

  /// Not remembered as a failure for good: the file may still be arriving.
  static VideoPoster _forget(String videoPath) {
    unawaited(
      Future<void>.delayed(const Duration(seconds: 5), () {
        _known.remove(videoPath);
      }),
    );
    return _none;
  }

  /// FNV-1a over the UTF-16 units, as 16 hex digits. Stable across runs, which
  /// `String.hashCode` is not promised to be.
  static String _fnv(String text) {
    var hash = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    for (final unit in text.codeUnits) {
      hash ^= unit;
      hash *= prime;
    }
    return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }
}
