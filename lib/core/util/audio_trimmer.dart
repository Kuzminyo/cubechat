import 'dart:io';

import 'package:flutter/services.dart';

import 'debug_log.dart';

/// Cuts a section out of a recorded voice note.
///
/// The work is native on both platforms because the recording is AAC-LC in an
/// MP4 container: the sample tables describe every frame's offset and size, so
/// there is no byte range you can slice out and still have a playable file.
/// Android re-muxes with `MediaExtractor`/`MediaMuxer`, iOS with
/// `AVAssetExportSession`. Both copy compressed frames across rather than
/// re-encoding, so a trim is lossless and takes milliseconds.
///
/// **Best effort by design.** Every failure — an unimplemented channel on a
/// platform that has none, a codec the muxer refuses, a full disk — comes back
/// as null, and [trimOrOriginal] then hands the caller the untrimmed file. The
/// worst case is a voice note that is longer than the user wanted, never one
/// that fails to send.
class AudioTrimmer {
  AudioTrimmer({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('cubechat/audio_trim');

  final MethodChannel _channel;

  /// Below this there is nothing worth cutting, and a very short range risks
  /// producing a file with no frames at all.
  static const int minTrimmedMs = 400;

  /// Trim [sourcePath] to `[startMs, endMs)`, or return the original path when
  /// the cut is not worth making or could not be made.
  ///
  /// [fullDurationMs] is what the recorder measured; a selection that still
  /// covers essentially the whole recording is skipped rather than paying for
  /// a re-mux that changes nothing.
  Future<String> trimOrOriginal({
    required String sourcePath,
    required int startMs,
    required int endMs,
    required int fullDurationMs,
  }) async {
    final trimmed = await trim(
      sourcePath: sourcePath,
      startMs: startMs,
      endMs: endMs,
      fullDurationMs: fullDurationMs,
    );
    return trimmed ?? sourcePath;
  }

  /// The raw attempt: the trimmed file's path, or null when nothing was done.
  Future<String?> trim({
    required String sourcePath,
    required int startMs,
    required int endMs,
    required int fullDurationMs,
  }) async {
    final start = startMs.clamp(0, fullDurationMs);
    final end = endMs.clamp(0, fullDurationMs);
    if (end - start < minTrimmedMs) return null;
    // Within a hair of the whole thing: nothing to gain from a re-mux.
    if (start <= 0 && end >= fullDurationMs - 50) return null;

    final dest = _destinationFor(sourcePath);
    try {
      final result = await _channel.invokeMethod<String>('trim', {
        'source': sourcePath,
        'dest': dest,
        'startMs': start,
        'endMs': end,
      });
      if (result == null) {
        DebugLog.instance.log('VOICE', 'trim declined by platform');
        return null;
      }
      final file = File(result);
      if (!await file.exists() || await file.length() < 128) {
        DebugLog.instance.log('VOICE', 'trim produced an empty file');
        return null;
      }
      DebugLog.instance.log(
        'VOICE',
        'trimmed ${fullDurationMs}ms -> ${end - start}ms',
      );
      return result;
    } on MissingPluginException {
      // Desktop/web, or an older build of the native side.
      DebugLog.instance.log('VOICE', 'no audio trimmer on this platform');
      return null;
    } catch (e) {
      DebugLog.instance.log('VOICE', 'trim failed: $e');
      return null;
    }
  }

  static String _destinationFor(String sourcePath) {
    final dot = sourcePath.lastIndexOf('.');
    final stem = dot > 0 ? sourcePath.substring(0, dot) : sourcePath;
    final ext = dot > 0 ? sourcePath.substring(dot) : '.m4a';
    return '$stem-trim$ext';
  }
}
