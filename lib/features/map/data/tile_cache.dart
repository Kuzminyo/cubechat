import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/util/debug_log.dart';

/// Map tiles, kept on disk and fetched a few at a time.
///
/// Two problems, one cause. Pinching quickly asks for every tile of every zoom
/// level it passes through, and the default provider turns each one into its own
/// HTTP request immediately — hundreds of sockets and hundreds of PNG decodes in
/// flight at once, which is what took the app down mid-gesture. And nothing was
/// ever kept, so the same squares were re-fetched on every visit and there was
/// no map at all without a connection.
///
/// So: at most [_maxConcurrent] requests are in the air, the rest queue; and
/// every tile that arrives is written to the cache directory, where it is read
/// from next time in preference to the network. Offline, the map is whatever you
/// have already looked at — which, for the places a person actually goes, is
/// most of it.
class CachedTileProvider extends TileProvider {
  CachedTileProvider({this.userAgent = 'cubechat'});

  final String userAgent;

  static final _store = _TileStore();

  /// Warm the cache directory and evict what has gone stale. Safe to call more
  /// than once; only the first does any work.
  static Future<void> prepare() => _store.prepare();

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      _CachedTile(
        url: getTileUrl(coordinates, options),
        // Coordinates make the filename, so no hashing is needed and the cache
        // is inspectable: 14_9581_5524.png is exactly the square it looks like.
        name: '${coordinates.z}_${coordinates.x}_${coordinates.y}.png',
        userAgent: userAgent,
      );
}

/// How many tile requests may be outstanding at once.
///
/// Six is roughly a screenful in flight while a pinch settles. It is a limit on
/// sockets *and* on decodes: each response becomes an image, and it was the
/// unbounded pile of both that killed the process rather than the traffic
/// itself.
const int _maxConcurrent = 6;

/// Tiles older than this are re-fetched when there is a connection. Streets do
/// change, but not weekly, and a stale tile beats an empty one.
const Duration _maxAge = Duration(days: 30);

/// Roughly 60 MB of squares — a few cities' worth at the zooms people use.
const int _maxCacheBytes = 60 * 1024 * 1024;

class _TileStore {
  Directory? _dir;
  Future<void>? _preparing;

  /// Requests waiting for a slot, oldest first.
  final _queue = <Completer<void>>[];
  int _active = 0;

  Future<void> prepare() => _preparing ??= _prepare();

  Future<void> _prepare() async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/map_tiles');
      if (!dir.existsSync()) await dir.create(recursive: true);
      _dir = dir;
      unawaited(_evict(dir));
    } catch (e) {
      // No cache directory is survivable: every tile then goes to the network,
      // which is exactly the old behaviour.
      DebugLog.instance.log('MAP', 'tile cache unavailable: $e');
    }
  }

  /// Drop tiles that are too old, then the oldest ones until the cache fits.
  Future<void> _evict(Directory dir) async {
    try {
      final now = DateTime.now();
      final files = <({File file, DateTime at, int size})>[];
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final stat = await entity.stat();
        if (now.difference(stat.modified) > _maxAge) {
          await entity.delete().catchError((_) => entity);
          continue;
        }
        total += stat.size;
        files.add((file: entity, at: stat.modified, size: stat.size));
      }
      if (total <= _maxCacheBytes) return;
      files.sort((a, b) => a.at.compareTo(b.at));
      for (final entry in files) {
        if (total <= _maxCacheBytes) break;
        await entry.file.delete().catchError((_) => entry.file);
        total -= entry.size;
      }
    } catch (e) {
      DebugLog.instance.log('MAP', 'tile cache eviction failed: $e');
    }
  }

  Future<Uint8List> bytesFor(String url, String name, String userAgent) async {
    await prepare();
    final dir = _dir;
    final file = dir == null ? null : File('${dir.path}/$name');

    if (file != null && file.existsSync()) {
      try {
        final stat = await file.stat();
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          // Fresh enough, or the only copy there is going to be — a tile read
          // from disk with no connection is the whole point of keeping it.
          if (DateTime.now().difference(stat.modified) <= _maxAge) return bytes;
          final refreshed = await _download(url, userAgent);
          if (refreshed == null) return bytes;
          unawaited(_write(file, refreshed));
          return refreshed;
        }
      } catch (_) {
        // Unreadable cache entry falls through to a fetch.
      }
    }

    final bytes = await _download(url, userAgent);
    if (bytes == null) throw const _TileUnavailable();
    if (file != null) unawaited(_write(file, bytes));
    return bytes;
  }

  Future<void> _write(File file, Uint8List bytes) async {
    try {
      await file.writeAsBytes(bytes, flush: false);
    } catch (_) {
      // A full disk must not fail the tile that is already in hand.
    }
  }

  Future<Uint8List?> _download(String url, String userAgent) async {
    await _acquire();
    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 12)
        ..userAgent = userAgent;
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close().timeout(
            const Duration(seconds: 20),
          );
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      // Offline, refused, timed out — the caller falls back to the cached copy
      // if it has one and to an empty tile if it does not.
      return null;
    } finally {
      client?.close(force: true);
      _release();
    }
  }

  Future<void> _acquire() {
    if (_active < _maxConcurrent) {
      _active++;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _queue.add(waiter);
    return waiter.future;
  }

  void _release() {
    if (_queue.isNotEmpty) {
      _queue.removeAt(0).complete();
      return;
    }
    _active--;
  }
}

class _TileUnavailable implements Exception {
  const _TileUnavailable();

  @override
  String toString() => 'tile unavailable';
}

@immutable
class _CachedTile extends ImageProvider<_CachedTile> {
  const _CachedTile({
    required this.url,
    required this.name,
    required this.userAgent,
  });

  final String url;
  final String name;
  final String userAgent;

  @override
  Future<_CachedTile> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_CachedTile>(this);

  @override
  ImageStreamCompleter loadImage(
    _CachedTile key,
    ImageDecoderCallback decode,
  ) =>
      MultiFrameImageStreamCompleter(
        codec: _codec(decode),
        scale: 1,
        debugLabel: url,
      );

  Future<ui.Codec> _codec(ImageDecoderCallback decode) async {
    final bytes = await CachedTileProvider._store.bytesFor(
      url,
      name,
      userAgent,
    );
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) => other is _CachedTile && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
