import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../util/debug_log.dart';
import 'inner_payload.dart';

/// In-memory reassembly buffer for an in-flight image.
///
/// Chunks may arrive out of order (the mesh has no ordering guarantees);
/// we collect them keyed by `seq` and finalise the moment we have all
/// `total` slices.
class _PendingImage {
  _PendingImage({
    required this.total,
    required this.mime,
    required this.startedAt,
  });

  final int total;
  final String mime;
  final DateTime startedAt;
  final Map<int, Uint8List> chunks = {};

  bool get isComplete => chunks.length == total;

  /// Concatenate chunks in seq order. Caller is responsible for confirming
  /// [isComplete] first.
  Uint8List assemble() {
    final ordered = List<Uint8List>.generate(total, (i) => chunks[i]!);
    final totalBytes = ordered.fold<int>(0, (s, c) => s + c.length);
    final out = Uint8List(totalBytes);
    var cursor = 0;
    for (final c in ordered) {
      out.setRange(cursor, cursor += c.length, c);
    }
    return out;
  }
}

/// Aggregates [ImageChunk] payloads keyed by imageId, expiring partial
/// transfers that stall for more than [staleAfter]. Once all chunks have
/// arrived, the bytes are written to a file under the app cache directory
/// and the path is returned to the caller.
class ImageReassembler {
  ImageReassembler({this.staleAfter = const Duration(minutes: 2)});

  final Duration staleAfter;
  final Map<String, _PendingImage> _pending = {};

  /// Feed a chunk into the reassembly buffer. Returns the assembled
  /// [Uint8List] + mime when this chunk completes the image; otherwise
  /// returns null and the chunk is buffered.
  ({Uint8List bytes, String mime, Uint8List imageId})? ingest(ImageChunk chunk) {
    _gc();
    final key = _keyOf(chunk.imageId);
    final entry = _pending.putIfAbsent(
      key,
      () => _PendingImage(
        total: chunk.total,
        mime: chunk.mime,
        startedAt: DateTime.now(),
      ),
    );
    if (entry.total != chunk.total) {
      DebugLog.instance.log('IMG',
          'chunk total mismatch for $key — discarding image buffer');
      _pending.remove(key);
      return null;
    }
    entry.chunks[chunk.seq] = chunk.data;
    // Sample every 25th chunk so the log doesn't drown in progress lines
    // on big payloads. Completion + first chunk are always logged.
    final n = entry.chunks.length;
    if (n == 1 || n == entry.total || n % 25 == 0) {
      DebugLog.instance.log('IMG', 'buf $key: $n/${entry.total}');
    }
    if (entry.isComplete) {
      final bytes = entry.assemble();
      _pending.remove(key);
      return (bytes: bytes, mime: entry.mime, imageId: chunk.imageId);
    }
    return null;
  }

  /// Writes [bytes] under <appCache>/cubechat/images/<imageId>.<ext>.
  /// The extension is derived from [mime] so the OS image viewer behaves
  /// when the file is shared out.
  static Future<String> persistToCache({
    required Uint8List imageId,
    required Uint8List bytes,
    required String mime,
  }) async {
    final dir = Directory(
      '${(await getApplicationCacheDirectory()).path}/cubechat/images',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final ext = _extensionFor(mime);
    final hex = imageId
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final file = File('${dir.path}/$hex$ext');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  void _gc() {
    final now = DateTime.now();
    _pending.removeWhere((_, p) => now.difference(p.startedAt) > staleAfter);
  }

  static String _keyOf(Uint8List id) =>
      id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static String _extensionFor(String mime) {
    switch (mime.toLowerCase()) {
      case 'image/jpeg':
      case 'image/jpg':
        return '.jpg';
      case 'image/png':
        return '.png';
      case 'image/webp':
        return '.webp';
      case 'image/gif':
        return '.gif';
      default:
        return '.bin';
    }
  }
}

/// In-memory buffer for one in-flight voice message. Same shape as
/// [_PendingImage] but carries the [durationMs] so the chat UI can label
/// the bubble's playback timer the moment the *first* chunk arrives, even
/// before the rest is on disk.
class _PendingAudio {
  _PendingAudio({
    required this.total,
    required this.mime,
    required this.durationMs,
    required this.startedAt,
  });

  final int total;
  final String mime;
  final int durationMs;
  final DateTime startedAt;
  final Map<int, Uint8List> chunks = {};

  bool get isComplete => chunks.length == total;

  Uint8List assemble() {
    final ordered = List<Uint8List>.generate(total, (i) => chunks[i]!);
    final totalBytes = ordered.fold<int>(0, (s, c) => s + c.length);
    final out = Uint8List(totalBytes);
    var cursor = 0;
    for (final c in ordered) {
      out.setRange(cursor, cursor += c.length, c);
    }
    return out;
  }
}

/// Mirror of [ImageReassembler] for audio chunks. Returns the assembled
/// bytes + duration the moment the last chunk lands.
class AudioReassembler {
  AudioReassembler({this.staleAfter = const Duration(minutes: 5)});

  final Duration staleAfter;
  final Map<String, _PendingAudio> _pending = {};

  ({Uint8List bytes, String mime, int durationMs, Uint8List audioId})? ingest(
      AudioChunk chunk) {
    _gc();
    final key = _keyOf(chunk.audioId);
    final entry = _pending.putIfAbsent(
      key,
      () => _PendingAudio(
        total: chunk.total,
        mime: chunk.mime,
        durationMs: chunk.durationMs,
        startedAt: DateTime.now(),
      ),
    );
    if (entry.total != chunk.total) {
      DebugLog.instance.log('VOICE',
          'chunk total mismatch for $key — discarding audio buffer');
      _pending.remove(key);
      return null;
    }
    entry.chunks[chunk.seq] = chunk.data;
    final n = entry.chunks.length;
    if (n == 1 || n == entry.total || n % 25 == 0) {
      DebugLog.instance.log('VOICE', 'buf $key: $n/${entry.total}');
    }
    if (entry.isComplete) {
      final bytes = entry.assemble();
      _pending.remove(key);
      return (
        bytes: bytes,
        mime: entry.mime,
        durationMs: entry.durationMs,
        audioId: chunk.audioId,
      );
    }
    return null;
  }

  static Future<String> persistToCache({
    required Uint8List audioId,
    required Uint8List bytes,
    required String mime,
  }) async {
    final dir = Directory(
      '${(await getApplicationCacheDirectory()).path}/cubechat/audio',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final ext = _audioExtensionFor(mime);
    final hex =
        audioId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final file = File('${dir.path}/$hex$ext');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  void _gc() {
    final now = DateTime.now();
    _pending.removeWhere((_, p) => now.difference(p.startedAt) > staleAfter);
  }

  static String _keyOf(Uint8List id) =>
      id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static String _audioExtensionFor(String mime) {
    switch (mime.toLowerCase()) {
      case 'audio/aac':
      case 'audio/mp4':
      case 'audio/x-m4a':
        return '.m4a';
      case 'audio/opus':
      case 'audio/ogg':
        return '.opus';
      case 'audio/wav':
        return '.wav';
      default:
        return '.bin';
    }
  }
}

/// Mirror of [AudioReassembler] for video clips. Different cache directory,
/// different mime → extension mapping; same chunk-buffer logic.
class VideoReassembler {
  VideoReassembler({this.staleAfter = const Duration(minutes: 10)});

  final Duration staleAfter;
  final Map<String, _PendingAudio> _pending = {};

  ({Uint8List bytes, String mime, int durationMs, Uint8List videoId})? ingest(
      VideoChunk chunk) {
    _gc();
    final key = _keyOf(chunk.videoId);
    final entry = _pending.putIfAbsent(
      key,
      () => _PendingAudio(
        total: chunk.total,
        mime: chunk.mime,
        durationMs: chunk.durationMs,
        startedAt: DateTime.now(),
      ),
    );
    if (entry.total != chunk.total) {
      DebugLog.instance.log('CIRCLE',
          'chunk total mismatch for $key — discarding video buffer');
      _pending.remove(key);
      return null;
    }
    entry.chunks[chunk.seq] = chunk.data;
    final n = entry.chunks.length;
    if (n == 1 || n == entry.total || n % 50 == 0) {
      DebugLog.instance.log('CIRCLE', 'buf $key: $n/${entry.total}');
    }
    if (entry.isComplete) {
      final bytes = entry.assemble();
      _pending.remove(key);
      return (
        bytes: bytes,
        mime: entry.mime,
        durationMs: entry.durationMs,
        videoId: chunk.videoId,
      );
    }
    return null;
  }

  static Future<String> persistToCache({
    required Uint8List videoId,
    required Uint8List bytes,
    required String mime,
  }) async {
    final dir = Directory(
      '${(await getApplicationCacheDirectory()).path}/cubechat/video',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final ext = _videoExtensionFor(mime);
    final hex =
        videoId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final file = File('${dir.path}/$hex$ext');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  void _gc() {
    final now = DateTime.now();
    _pending.removeWhere((_, p) => now.difference(p.startedAt) > staleAfter);
  }

  static String _keyOf(Uint8List id) =>
      id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static String _videoExtensionFor(String mime) {
    switch (mime.toLowerCase()) {
      case 'video/mp4':
        return '.mp4';
      case 'video/quicktime':
        return '.mov';
      case 'video/webm':
        return '.webm';
      default:
        return '.bin';
    }
  }
}
