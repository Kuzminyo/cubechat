import 'dart:collection';
import 'dart:typed_data';

import 'envelope.dart';

/// LRU + time-based dedup cache for mesh-relay forwarding.
///
/// Keyed by the pair `(originPubkeyHash, msgId)` — the same pair on the wire
/// = the same logical message, regardless of which relay path delivered it
/// to us. We use this to:
///
/// 1. Skip forwarding a frame we've already forwarded (kill loops).
/// 2. Skip delivering a duplicate copy to the chat UI when the same message
///    arrives via two different paths.
///
/// Sizing: bitchat's dedup is around the same shape — a few hundred recent
/// messages over ~10 minutes is enough for realistic mesh density.
class DedupCache {
  DedupCache({
    this.capacity = 1024,
    this.ttl = const Duration(minutes: 10),
  });

  final int capacity;
  final Duration ttl;

  /// Insertion-ordered map gives free LRU eviction — when we exceed capacity
  /// we drop the oldest entry. Values store the insertion time for TTL
  /// expiration.
  final LinkedHashMap<String, DateTime> _entries = LinkedHashMap();

  /// True if this (origin, msgId) was seen within [ttl].
  bool isDuplicate(Uint8List origin, Uint8List msgId) {
    final key = _keyOf(origin, msgId);
    final at = _entries[key];
    if (at == null) return false;
    if (DateTime.now().difference(at) > ttl) {
      _entries.remove(key);
      return false;
    }
    return true;
  }

  /// Stamps this (origin, msgId) as seen now. Returns true if the entry was
  /// new, false if it was already present (and refreshes the timestamp).
  bool record(Uint8List origin, Uint8List msgId) {
    final key = _keyOf(origin, msgId);
    final existed = _entries.remove(key) != null; // re-insert to refresh order
    _entries[key] = DateTime.now();
    _evictExcess();
    return !existed;
  }

  /// Convenience: combine isDuplicate + record in one call. Returns true if
  /// the frame should be considered NEW (caller should process / forward).
  /// Returns false if it's a duplicate (caller should drop).
  bool accept(Uint8List origin, Uint8List msgId) {
    if (isDuplicate(origin, msgId)) return false;
    record(origin, msgId);
    return true;
  }

  void clear() => _entries.clear();

  int get size => _entries.length;

  void _evictExcess() {
    while (_entries.length > capacity) {
      final oldestKey = _entries.keys.first;
      _entries.remove(oldestKey);
    }
    // Opportunistic TTL sweep: drop expired entries from the head while we're
    // here. We don't sweep the whole map to keep this O(small) on average.
    final cutoff = DateTime.now().subtract(ttl);
    final toRemove = <String>[];
    for (final entry in _entries.entries) {
      if (entry.value.isBefore(cutoff)) {
        toRemove.add(entry.key);
      } else {
        break; // map is insertion-ordered, rest is newer
      }
    }
    for (final k in toRemove) {
      _entries.remove(k);
    }
  }

  static String _keyOf(Uint8List origin, Uint8List msgId) {
    final sb = StringBuffer();
    for (final b in origin) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    sb.write('/');
    for (final b in msgId) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}

/// Convenience helper for the messaging layer: dedup keyed on a parsed
/// [TransportEnvelope]'s origin + msgId.
extension DedupOnEnvelope on DedupCache {
  bool acceptEnvelope(TransportEnvelope env) =>
      accept(env.originPubkeyHash, env.msgId);
}
