import 'dart:typed_data';

/// One held frame awaiting an opportunistic delivery. [frameBytes] is the
/// fully-encoded, end-to-end-encrypted wire frame exactly as it arrived —
/// the relay can't read it, it only carries it.
class StoredFrame {
  StoredFrame({
    required this.frameBytes,
    required this.storedAt,
    required this.dedupKey,
  });

  final Uint8List frameBytes;
  final DateTime storedAt;

  /// `originHex/msgIdHex` — so we never hold two copies of the same frame
  /// for the same destination.
  final String dedupKey;
}

/// Opportunistic store-and-forward buffer for the BLE mesh.
///
/// When a transport frame addressed to some peer C passes through us but C
/// isn't reachable right now, we hold an encrypted copy keyed by C's pubkey
/// hash. The next time C connects to us directly we flush the held frames to
/// them — the "data mule" pattern: a phone physically carries messages
/// between two disconnected pockets of the mesh.
///
/// Everything stored is already SealedBox-encrypted + signed end-to-end, so
/// the relay learns nothing beyond routing metadata (origin / dest hashes,
/// msgId, length — the last of which short messages already pad away).
///
/// Bounded three ways so a hostile or chatty mesh can't exhaust memory:
///   * [ttl]        — frames older than this are dropped on the next touch.
///   * [perDestCap] — at most this many frames held for any one destination.
///   * [capacity]   — global frame ceiling; oldest-first eviction beyond it.
///
/// **Crucially**, [ttl] must not exceed the receiver's replay window: a held
/// frame is delivered with its original signed timestamp, so if it sat here
/// longer than the window the destination would reject it as stale. The
/// messaging layer keeps the two aligned (both 1 hour).
class StoreForwardCache {
  StoreForwardCache({
    this.capacity = 200,
    this.perDestCap = 50,
    this.ttl = const Duration(hours: 1),
  });

  final int capacity;
  final int perDestCap;
  final Duration ttl;

  final Map<String, List<StoredFrame>> _byDest = {};
  int _count = 0;

  int get size => _count;

  /// Hold [frameBytes] for the peer whose pubkey hashes to [destHash].
  /// No-op for a frame we're already holding for that destination.
  void store({
    required Uint8List destHash,
    required Uint8List frameBytes,
    required Uint8List origin,
    required Uint8List msgId,
  }) {
    _gc();
    final destKey = _hex(destHash);
    final dedupKey = '${_hex(origin)}/${_hex(msgId)}';
    final list = _byDest.putIfAbsent(destKey, () => <StoredFrame>[]);
    if (list.any((f) => f.dedupKey == dedupKey)) return;
    list.add(StoredFrame(
      frameBytes: Uint8List.fromList(frameBytes),
      storedAt: DateTime.now(),
      dedupKey: dedupKey,
    ));
    _count++;
    // Per-destination ceiling: drop that destination's oldest.
    while (list.length > perDestCap) {
      list.removeAt(0);
      _count--;
    }
    _evictGlobal();
  }

  /// Removes and returns every (non-expired) frame held for [destHash], in
  /// arrival order. Called when the destination becomes directly reachable.
  List<Uint8List> drainFor(Uint8List destHash) {
    _gc();
    final list = _byDest.remove(_hex(destHash));
    if (list == null || list.isEmpty) return const [];
    _count -= list.length;
    return list.map((f) => f.frameBytes).toList();
  }

  /// Number of distinct destinations we're currently holding frames for.
  int get destinationCount => _byDest.length;

  void clear() {
    _byDest.clear();
    _count = 0;
  }

  /// Flattens the buffer into serialisable rows for on-disk persistence.
  /// `dest` is the hex destination hash, `frame` the raw wire bytes, `at`
  /// the store time in epoch-ms, `dedup` the origin/msgId key.
  List<Map<String, dynamic>> exportEntries() {
    final out = <Map<String, dynamic>>[];
    for (final entry in _byDest.entries) {
      for (final f in entry.value) {
        out.add({
          'dest': entry.key,
          'frame': f.frameBytes,
          'at': f.storedAt.millisecondsSinceEpoch,
          'dedup': f.dedupKey,
        });
      }
    }
    return out;
  }

  /// Restores rows produced by [exportEntries], dropping any already past
  /// [ttl] and de-duplicating against what's already held. Used once at
  /// startup to repopulate the buffer from disk.
  void importEntries(List<Map<dynamic, dynamic>> entries) {
    final now = DateTime.now();
    for (final m in entries) {
      final destHex = m['dest'] as String?;
      final frame = m['frame'];
      final atMs = m['at'] as int?;
      final dedup = m['dedup'] as String?;
      if (destHex == null || frame == null || atMs == null || dedup == null) {
        continue;
      }
      final storedAt = DateTime.fromMillisecondsSinceEpoch(atMs);
      if (now.difference(storedAt) > ttl) continue; // already stale
      final bytes = frame is Uint8List
          ? frame
          : Uint8List.fromList((frame as List).cast<int>());
      final list = _byDest.putIfAbsent(destHex, () => <StoredFrame>[]);
      if (list.any((x) => x.dedupKey == dedup)) continue;
      list.add(StoredFrame(
        frameBytes: bytes,
        storedAt: storedAt,
        dedupKey: dedup,
      ));
      _count++;
    }
    _evictGlobal();
  }

  void _gc() {
    final cutoff = DateTime.now().subtract(ttl);
    final emptyDests = <String>[];
    for (final entry in _byDest.entries) {
      entry.value.removeWhere((f) {
        final stale = f.storedAt.isBefore(cutoff);
        if (stale) _count--;
        return stale;
      });
      if (entry.value.isEmpty) emptyDests.add(entry.key);
    }
    for (final k in emptyDests) {
      _byDest.remove(k);
    }
  }

  /// Evicts globally-oldest frames until we're back under [capacity].
  void _evictGlobal() {
    if (_count <= capacity) return;
    final all = <(String, StoredFrame)>[];
    for (final entry in _byDest.entries) {
      for (final f in entry.value) {
        all.add((entry.key, f));
      }
    }
    all.sort((a, b) => a.$2.storedAt.compareTo(b.$2.storedAt));
    var i = 0;
    while (_count > capacity && i < all.length) {
      final (destKey, frame) = all[i++];
      final list = _byDest[destKey];
      if (list == null) continue;
      if (list.remove(frame)) {
        _count--;
        if (list.isEmpty) _byDest.remove(destKey);
      }
    }
  }

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
