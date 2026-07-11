import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../util/debug_log.dart';
import 'inner_payload.dart';

/// In-memory reassembly buffer for an in-flight image.
class _PendingImage {
  _PendingImage({
    required this.total,
    required this.mime,
    required this.startedAt,
  }) : lastTouched = startedAt;

  final int total;
  final String mime;
  final DateTime startedAt;
  DateTime lastTouched;
  final Map<int, Uint8List> chunks = {};

  bool get isComplete => chunks.length == total;
  int get byteCount => chunks.values.fold<int>(0, (s, c) => s + c.length);

  void touch() {
    lastTouched = DateTime.now();
  }

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
/// transfers that stall. Buffers are also bounded by count and bytes so a
/// malicious peer cannot keep arbitrary partial media in memory until GC.
class ImageReassembler {
  ImageReassembler({
    this.staleAfter = const Duration(minutes: 2),
    this.maxPendingTransfers = 32,
    this.maxBufferedBytes = 4 * 1024 * 1024,
  });

  final Duration staleAfter;
  final int maxPendingTransfers;
  final int maxBufferedBytes;
  final Map<String, _PendingImage> _pending = {};

  ({Uint8List bytes, String mime, Uint8List imageId})? ingest(
      ImageChunk chunk) {
    _gc();
    final key = _keyOf(chunk.imageId);
    var entry = _pending[key];
    if (entry == null) {
      _evictUntilTransferSlotAvailable();
      if (_pending.length >= maxPendingTransfers) {
        DebugLog.instance.log('IMG', 'drop $key: pending image cap reached');
        return null;
      }
      entry = _PendingImage(
        total: chunk.total,
        mime: chunk.mime,
        startedAt: DateTime.now(),
      );
      _pending[key] = entry;
    }
    if (entry.total != chunk.total) {
      DebugLog.instance.log(
          'IMG', 'chunk total mismatch for $key - discarding image buffer');
      _pending.remove(key);
      return null;
    }
    final oldLen = entry.chunks[chunk.seq]?.length ?? 0;
    if (!_reserveBytesFor(key, chunk.data.length - oldLen)) {
      DebugLog.instance.log('IMG', 'drop $key: image buffer byte cap reached');
      _pending.remove(key);
      return null;
    }
    entry.chunks[chunk.seq] = chunk.data;
    entry.touch();

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
    final hex = imageId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final file = File('${dir.path}/$hex$ext');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  int get _bufferedBytes =>
      _pending.values.fold<int>(0, (s, p) => s + p.byteCount);

  void _gc() {
    final now = DateTime.now();
    _pending.removeWhere((_, p) => now.difference(p.startedAt) > staleAfter);
  }

  void _evictUntilTransferSlotAvailable() {
    while (_pending.length >= maxPendingTransfers && _pending.isNotEmpty) {
      _evictOldest();
    }
  }

  bool _reserveBytesFor(String currentKey, int deltaBytes) {
    if (deltaBytes <= 0) return true;
    while (_bufferedBytes + deltaBytes > maxBufferedBytes &&
        _pending.keys.any((k) => k != currentKey)) {
      _evictOldest(exceptKey: currentKey);
    }
    return _bufferedBytes + deltaBytes <= maxBufferedBytes;
  }

  void _evictOldest({String? exceptKey}) {
    String? oldestKey;
    DateTime? oldestTouched;
    for (final e in _pending.entries) {
      if (e.key == exceptKey) continue;
      final touched = e.value.lastTouched;
      if (oldestTouched == null || touched.isBefore(oldestTouched)) {
        oldestTouched = touched;
        oldestKey = e.key;
      }
    }
    if (oldestKey != null) {
      DebugLog.instance
          .log('IMG', 'evict pending image $oldestKey under buffer pressure');
      _pending.remove(oldestKey);
    }
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

class _PendingAudio {
  _PendingAudio({
    required this.total,
    required this.mime,
    required this.durationMs,
    required this.startedAt,
  }) : lastTouched = startedAt;

  final int total;
  final String mime;
  final int durationMs;
  final DateTime startedAt;
  DateTime lastTouched;
  final Map<int, Uint8List> chunks = {};

  bool get isComplete => chunks.length == total;
  int get byteCount => chunks.values.fold<int>(0, (s, c) => s + c.length);

  void touch() {
    lastTouched = DateTime.now();
  }

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

class AudioReassembler {
  AudioReassembler({
    this.staleAfter = const Duration(minutes: 5),
    this.maxPendingTransfers = 32,
    this.maxBufferedBytes = 4 * 1024 * 1024,
  });

  final Duration staleAfter;
  final int maxPendingTransfers;
  final int maxBufferedBytes;
  final Map<String, _PendingAudio> _pending = {};

  ({Uint8List bytes, String mime, int durationMs, Uint8List audioId})? ingest(
      AudioChunk chunk) {
    _gc();
    final key = _keyOf(chunk.audioId);
    var entry = _pending[key];
    if (entry == null) {
      _evictUntilTransferSlotAvailable();
      if (_pending.length >= maxPendingTransfers) {
        DebugLog.instance.log('VOICE', 'drop $key: pending audio cap reached');
        return null;
      }
      entry = _PendingAudio(
        total: chunk.total,
        mime: chunk.mime,
        durationMs: chunk.durationMs,
        startedAt: DateTime.now(),
      );
      _pending[key] = entry;
    }
    if (entry.total != chunk.total) {
      DebugLog.instance.log(
          'VOICE', 'chunk total mismatch for $key - discarding audio buffer');
      _pending.remove(key);
      return null;
    }
    final oldLen = entry.chunks[chunk.seq]?.length ?? 0;
    if (!_reserveBytesFor(key, chunk.data.length - oldLen)) {
      DebugLog.instance
          .log('VOICE', 'drop $key: audio buffer byte cap reached');
      _pending.remove(key);
      return null;
    }
    entry.chunks[chunk.seq] = chunk.data;
    entry.touch();

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
    final hex = audioId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final file = File('${dir.path}/$hex$ext');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  int get _bufferedBytes =>
      _pending.values.fold<int>(0, (s, p) => s + p.byteCount);

  void _gc() {
    final now = DateTime.now();
    _pending.removeWhere((_, p) => now.difference(p.startedAt) > staleAfter);
  }

  void _evictUntilTransferSlotAvailable() {
    while (_pending.length >= maxPendingTransfers && _pending.isNotEmpty) {
      _evictOldest();
    }
  }

  bool _reserveBytesFor(String currentKey, int deltaBytes) {
    if (deltaBytes <= 0) return true;
    while (_bufferedBytes + deltaBytes > maxBufferedBytes &&
        _pending.keys.any((k) => k != currentKey)) {
      _evictOldest(exceptKey: currentKey);
    }
    return _bufferedBytes + deltaBytes <= maxBufferedBytes;
  }

  void _evictOldest({String? exceptKey}) {
    String? oldestKey;
    DateTime? oldestTouched;
    for (final e in _pending.entries) {
      if (e.key == exceptKey) continue;
      final touched = e.value.lastTouched;
      if (oldestTouched == null || touched.isBefore(oldestTouched)) {
        oldestTouched = touched;
        oldestKey = e.key;
      }
    }
    if (oldestKey != null) {
      DebugLog.instance
          .log('VOICE', 'evict pending audio $oldestKey under buffer pressure');
      _pending.remove(oldestKey);
    }
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
