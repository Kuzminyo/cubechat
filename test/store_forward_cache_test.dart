import 'dart:typed_data';

import 'package:cubechat/core/transport/store_forward_cache.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _b(int fill, [int len = 8]) =>
    Uint8List(len)..fillRange(0, len, fill);
Uint8List _frame(int marker) => Uint8List.fromList([marker, 1, 2, 3]);

void main() {
  group('StoreForwardCache', () {
    test('stores and drains frames for a destination in order', () {
      final c = StoreForwardCache();
      final dest = _b(1);
      c.store(
          destHash: dest,
          frameBytes: _frame(10),
          origin: _b(9),
          msgId: _b(1, 16));
      c.store(
          destHash: dest,
          frameBytes: _frame(11),
          origin: _b(9),
          msgId: _b(2, 16));
      expect(c.size, 2);

      final drained = c.drainFor(dest);
      expect(drained.length, 2);
      expect(drained[0][0], 10);
      expect(drained[1][0], 11);
      // Drained entries are gone.
      expect(c.size, 0);
      expect(c.drainFor(dest), isEmpty);
    });

    test('frames for different destinations are isolated', () {
      final c = StoreForwardCache();
      c.store(
          destHash: _b(1),
          frameBytes: _frame(10),
          origin: _b(9),
          msgId: _b(1, 16));
      c.store(
          destHash: _b(2),
          frameBytes: _frame(20),
          origin: _b(9),
          msgId: _b(2, 16));
      expect(c.destinationCount, 2);
      expect(c.drainFor(_b(1)).single[0], 10);
      expect(c.drainFor(_b(2)).single[0], 20);
    });

    test('duplicate (origin,msgId) for the same dest is not stored twice', () {
      final c = StoreForwardCache();
      final dest = _b(1);
      c.store(
          destHash: dest,
          frameBytes: _frame(10),
          origin: _b(9),
          msgId: _b(7, 16));
      c.store(
          destHash: dest,
          frameBytes: _frame(10),
          origin: _b(9),
          msgId: _b(7, 16));
      expect(c.size, 1);
    });

    test('per-destination cap evicts the oldest', () {
      final c = StoreForwardCache(perDestCap: 2);
      final dest = _b(1);
      c.store(
          destHash: dest,
          frameBytes: _frame(1),
          origin: _b(9),
          msgId: _b(1, 16));
      c.store(
          destHash: dest,
          frameBytes: _frame(2),
          origin: _b(9),
          msgId: _b(2, 16));
      c.store(
          destHash: dest,
          frameBytes: _frame(3),
          origin: _b(9),
          msgId: _b(3, 16));
      final drained = c.drainFor(dest);
      // Oldest (marker 1) evicted; 2 and 3 remain.
      expect(drained.map((f) => f[0]).toList(), [2, 3]);
    });

    test('global capacity evicts oldest across destinations', () {
      final c = StoreForwardCache(capacity: 2, perDestCap: 100);
      c.store(
          destHash: _b(1),
          frameBytes: _frame(1),
          origin: _b(9),
          msgId: _b(1, 16));
      c.store(
          destHash: _b(2),
          frameBytes: _frame(2),
          origin: _b(9),
          msgId: _b(2, 16));
      c.store(
          destHash: _b(3),
          frameBytes: _frame(3),
          origin: _b(9),
          msgId: _b(3, 16));
      // One frame (the oldest) must have been evicted to stay at capacity 2.
      expect(c.size, 2);
    });

    test('expired frames are dropped on the next touch', () async {
      final c = StoreForwardCache(ttl: const Duration(milliseconds: 10));
      c.store(
          destHash: _b(1),
          frameBytes: _frame(1),
          origin: _b(9),
          msgId: _b(1, 16));
      await Future<void>.delayed(const Duration(milliseconds: 25));
      // A later store() triggers GC, which sweeps the now-stale _b(1) frame.
      c.store(
          destHash: _b(2),
          frameBytes: _frame(2),
          origin: _b(9),
          msgId: _b(2, 16));
      expect(c.drainFor(_b(1)), isEmpty);
      expect(c.drainFor(_b(2)).single[0], 2);
    });

    test('clear empties everything', () {
      final c = StoreForwardCache();
      c.store(
          destHash: _b(1),
          frameBytes: _frame(1),
          origin: _b(9),
          msgId: _b(1, 16));
      c.clear();
      expect(c.size, 0);
      expect(c.destinationCount, 0);
    });

    test('export/import round-trips held frames', () {
      final a = StoreForwardCache();
      a.store(
          destHash: _b(1),
          frameBytes: _frame(10),
          origin: _b(9),
          msgId: _b(1, 16));
      a.store(
          destHash: _b(1),
          frameBytes: _frame(11),
          origin: _b(9),
          msgId: _b(2, 16));
      a.store(
          destHash: _b(2),
          frameBytes: _frame(20),
          origin: _b(9),
          msgId: _b(3, 16));

      final rows = a.exportEntries();
      expect(rows.length, 3);

      final b = StoreForwardCache();
      b.importEntries(rows);
      expect(b.size, 3);
      expect(b.destinationCount, 2);
      expect(b.drainFor(_b(1)).map((f) => f[0]).toList(), [10, 11]);
      expect(b.drainFor(_b(2)).single[0], 20);
    });

    test('import drops entries older than the TTL', () {
      final src = StoreForwardCache();
      src.store(
          destHash: _b(1),
          frameBytes: _frame(1),
          origin: _b(9),
          msgId: _b(1, 16));
      final rows = src.exportEntries();
      // Backdate the row well beyond the TTL.
      rows[0]['at'] = DateTime.now()
          .subtract(const Duration(hours: 5))
          .millisecondsSinceEpoch;

      final dst = StoreForwardCache(ttl: const Duration(hours: 1));
      dst.importEntries(rows);
      expect(dst.size, 0);
    });

    test('import accepts frame bytes as a plain int list', () {
      final dst = StoreForwardCache();
      dst.importEntries([
        {
          'dest': '0101010101010101',
          'frame': <int>[7, 8, 9],
          'at': DateTime.now().millisecondsSinceEpoch,
          'dedup': 'x/y',
        }
      ]);
      expect(dst.size, 1);
    });

    group('newestStoredAt', () {
      // This is what keeps the scan cadence honest. "We owe someone a
      // delivery" stays true for the buffer's full one-hour TTL, and wiring
      // that straight to the scanner pinned the radio to its expensive cadence
      // for an hour after a single undeliverable message — most of the battery
      // complaint on a backgrounded phone. The cadence asks how *fresh* the
      // debt is instead, which is only answerable from here.

      test('is null while nothing is held', () {
        expect(StoreForwardCache().newestStoredAt, isNull);
      });

      test('reports the most recent frame, not the first', () {
        final c = StoreForwardCache();
        c.store(
            destHash: _b(1),
            frameBytes: _frame(10),
            origin: _b(9),
            msgId: _b(1, 16));
        final afterFirst = c.newestStoredAt;
        expect(afterFirst, isNotNull);

        c.store(
            destHash: _b(2),
            frameBytes: _frame(20),
            origin: _b(9),
            msgId: _b(2, 16));
        // Across destinations, too — the buffer is keyed by destination but
        // the question is about the buffer as a whole.
        expect(
          c.newestStoredAt!.isBefore(afterFirst!),
          isFalse,
          reason: 'a newer frame must not move the timestamp backwards',
        );
      });

      test('an old restored frame does not read as fresh', () {
        // The case that matters after a restart: frames come back from disk
        // carrying their original store time. If import reset the clock, every
        // relaunch would look like a fresh delivery debt and re-pin the radio.
        final c = StoreForwardCache();
        final old = DateTime.now().subtract(const Duration(minutes: 30));
        c.importEntries([
          {
            'dest': '0101010101010101',
            'frame': _frame(10),
            'at': old.millisecondsSinceEpoch,
            'dedup': 'a/b',
          },
        ]);
        expect(c.size, 1);
        expect(c.newestStoredAt, isNotNull);
        expect(
          DateTime.now().difference(c.newestStoredAt!),
          greaterThan(const Duration(minutes: 29)),
          reason: 'a frame restored from disk must keep its original age',
        );
      });

      test('goes back to null once the buffer is drained', () {
        final c = StoreForwardCache();
        c.store(
            destHash: _b(1),
            frameBytes: _frame(10),
            origin: _b(9),
            msgId: _b(1, 16));
        c.drainFor(_b(1));
        expect(c.newestStoredAt, isNull);
      });
    });
  });
}
