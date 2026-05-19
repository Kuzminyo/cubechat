import 'dart:typed_data';

import 'package:cubechat/core/transport/dedup_cache.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(int seed, int len) =>
    Uint8List.fromList(List.generate(len, (i) => (seed + i) & 0xFF));

void main() {
  group('DedupCache', () {
    test('first record() is new, second is duplicate', () {
      final cache = DedupCache();
      final origin = _bytes(1, 8);
      final msgId = _bytes(100, 16);

      expect(cache.accept(origin, msgId), isTrue);
      expect(cache.accept(origin, msgId), isFalse);
    });

    test('different origins are independent', () {
      final cache = DedupCache();
      final msgId = _bytes(100, 16);

      expect(cache.accept(_bytes(1, 8), msgId), isTrue);
      expect(cache.accept(_bytes(2, 8), msgId), isTrue);
      expect(cache.accept(_bytes(1, 8), msgId), isFalse);
    });

    test('different msgIds are independent', () {
      final cache = DedupCache();
      final origin = _bytes(1, 8);

      expect(cache.accept(origin, _bytes(10, 16)), isTrue);
      expect(cache.accept(origin, _bytes(11, 16)), isTrue);
      expect(cache.accept(origin, _bytes(10, 16)), isFalse);
    });

    test('LRU eviction beyond capacity', () {
      final cache = DedupCache(capacity: 3);
      cache.accept(_bytes(1, 8), _bytes(1, 16));
      cache.accept(_bytes(1, 8), _bytes(2, 16));
      cache.accept(_bytes(1, 8), _bytes(3, 16));
      expect(cache.size, 3);

      // Adding a 4th should evict the oldest (msgId=1).
      cache.accept(_bytes(1, 8), _bytes(4, 16));
      expect(cache.size, 3);

      // msgId=1 is no longer remembered, so it counts as new again.
      expect(cache.accept(_bytes(1, 8), _bytes(1, 16)), isTrue);
    });

    test('TTL expiration treats stale entries as new', () async {
      final cache = DedupCache(ttl: const Duration(milliseconds: 50));
      cache.accept(_bytes(1, 8), _bytes(1, 16));

      // Within the window — still duplicate.
      expect(cache.accept(_bytes(1, 8), _bytes(1, 16)), isFalse);

      // After TTL — should look new again.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(cache.accept(_bytes(1, 8), _bytes(1, 16)), isTrue);
    });

    test('clear empties the cache', () {
      final cache = DedupCache();
      cache.accept(_bytes(1, 8), _bytes(1, 16));
      expect(cache.size, 1);
      cache.clear();
      expect(cache.size, 0);
      expect(cache.accept(_bytes(1, 8), _bytes(1, 16)), isTrue);
    });
  });
}
