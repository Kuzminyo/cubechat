import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../util/debug_log.dart';
import 'opus_codec.dart';

/// A path the platform can do something with, for a voice note on disk.
///
/// An Opus note is Ogg, and iOS opens no Ogg at all — not its player, not its
/// speech recogniser. So a note is decoded to WAV the first time it is wanted
/// and the WAV is what gets played, previewed and transcribed; everything
/// else — AAC notes from before, files that are not notes — comes back as it
/// was given. Android would play the Ogg itself from Android 10, but not on
/// the Android 7 to 9 phones this app still runs on, and one path on both
/// platforms is one path to get right.
///
/// The WAV lives in the cache directory: the OS may take it back, and then it
/// is simply made again from the note, which is the thing that is kept.
abstract final class PlayableVoice {
  /// [path] itself, or a decoded WAV of it when it is Ogg Opus. Falls back to
  /// [path] if decoding fails, so a player that can open it still gets a try.
  static Future<String> pathFor(String path) async {
    try {
      final source = File(path);
      if (!await isOggOpus(source)) return path;
      final wav = await _wavFor(source);
      if (await wav.exists() && await wav.length() > 44) return wav.path;
      final ogg = await source.readAsBytes();
      final bytes = await decodeOggOpusToWav(ogg);
      await wav.parent.create(recursive: true);
      final part = File('${wav.path}.part');
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(wav.path);
      return wav.path;
    } catch (e) {
      DebugLog.instance.log('VOICE', 'opus decode failed: $e');
      return path;
    }
  }

  /// Ogg by its first four bytes, not its name: a forwarded or saved note can
  /// arrive under any extension.
  static Future<bool> isOggOpus(File file) async {
    if (!await file.exists()) return false;
    final raf = await file.open();
    try {
      final head = await raf.read(4);
      return head.length == 4 &&
          head[0] == 0x4F &&
          head[1] == 0x67 &&
          head[2] == 0x67 &&
          head[3] == 0x53;
    } finally {
      await raf.close();
    }
  }

  /// One WAV per note, named by the note and its size so a different file
  /// under a reused name never plays the old one.
  static Future<File> _wavFor(File source) async {
    final cache = await getTemporaryDirectory();
    final name = source.uri.pathSegments.last;
    final size = await source.length();
    return File(
      '${cache.path}${Platform.pathSeparator}voice-wav'
      '${Platform.pathSeparator}$name-$size.wav',
    );
  }
}
