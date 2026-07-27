import 'dart:typed_data';

import 'package:cubechat/core/transport/peer_id.dart';
import 'package:cubechat/core/transport/store_forward_cache.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _key(int base) =>
    Uint8List.fromList(List.generate(32, (i) => (base + i) & 0xFF));

DateTime _at(int epoch) => DateTime.fromMillisecondsSinceEpoch(
      epoch * PeerId.rotationPeriod.inMilliseconds,
    );

/// Uint8List doesn't override `==`, so a `contains` matcher over raw ids
/// compares by identity and silently never matches. Compare the hex instead.
List<String> _hexAll(List<Uint8List> ids) => ids.map(PeerId.hex).toList();

void main() {
  group('PeerId derivation', () {
    test('is deterministic — the same key and epoch always agree', () async {
      final a = await PeerId.derive(_key(1), 100);
      final b = await PeerId.derive(_key(1), 100);
      expect(a, equals(b));
      expect(a, hasLength(PeerId.len));
    });

    test('changes every epoch, which is the whole point', () async {
      final e100 = await PeerId.derive(_key(1), 100);
      final e101 = await PeerId.derive(_key(1), 101);
      final e102 = await PeerId.derive(_key(1), 102);
      expect(e100, isNot(equals(e101)));
      expect(e101, isNot(equals(e102)));
      expect(e100, isNot(equals(e102)));
    });

    test('two peers never share an id in the same epoch', () async {
      final alice = await PeerId.derive(_key(1), 100);
      final bob = await PeerId.derive(_key(90), 100);
      expect(alice, isNot(equals(bob)));
    });

    test('is not the old fixed hash — a stale build cannot be mistaken for a '
        'current one', () async {
      final rotating = await PeerId.derive(_key(1), 100);
      final legacy = await PeerId.legacy(_key(1));
      expect(rotating, isNot(equals(legacy)));
    });

    test('legacy id is stable forever, by definition', () async {
      expect(await PeerId.legacy(_key(1)), equals(await PeerId.legacy(_key(1))));
    });

    test('epoch advances with wall-clock time', () {
      final e = PeerId.epochAt(_at(5000));
      expect(PeerId.epochAt(_at(5001)), e + 1);
      expect(
        PeerId.epochAt(_at(5000).add(PeerId.rotationPeriod ~/ 2)),
        e,
        reason: 'mid-period stays in the same epoch',
      );
    });

    test('the acceptance window covers the neighbours, not just now', () {
      final now = _at(5000);
      expect(PeerId.activeEpochs(now), [4999, 5000, 5001]);
    });

    test('deriveActive matches deriving each active epoch by hand', () async {
      final now = _at(5000);
      final active = await PeerId.deriveActive(_key(1), now);
      expect(active, hasLength(3));
      expect(active[0], equals(await PeerId.derive(_key(1), 4999)));
      expect(active[1], equals(await PeerId.derive(_key(1), 5000)));
      expect(active[2], equals(await PeerId.derive(_key(1), 5001)));
    });

    test('the window absorbs a frame minted just before a boundary', () async {
      // Sent at the tail of epoch 5000, delivered early in 5001.
      final sentAt = _at(5001).subtract(const Duration(minutes: 1));
      final arrivedAt = _at(5001).add(const Duration(minutes: 1));
      final stamped = await PeerId.derive(_key(1), PeerId.epochAt(sentAt));
      final accepted = await PeerId.deriveActive(_key(1), arrivedAt);
      expect(_hexAll(accepted), contains(PeerId.hex(stamped)));
    });

    test('the window absorbs a peer whose clock runs ahead', () async {
      final theirs = await PeerId.derive(_key(1), PeerId.epochAt(_at(5001)));
      final ours = await PeerId.deriveActive(_key(1), _at(5000));
      expect(_hexAll(ours), contains(PeerId.hex(theirs)));
    });

    test('a frame older than the window is no longer recognised', () async {
      final ancient = await PeerId.derive(_key(1), 4990);
      final accepted = await PeerId.deriveActive(_key(1), _at(5000));
      expect(_hexAll(accepted), isNot(contains(PeerId.hex(ancient))));
    });
  });

  group('PeerIdIndex', () {
    test('resolves an id back to the peer wearing it', () async {
      final index = PeerIdIndex();
      final roster = Object();
      final id = await PeerId.derive(_key(1), PeerId.epochAt(DateTime.now()));
      expect(
        await index.lookup(id, rosterToken: roster, pubkeys: [_key(1)]),
        equals(_key(1)),
      );
    });

    test('resolves every epoch in the window, not just the current one',
        () async {
      final index = PeerIdIndex();
      final roster = Object();
      final now = DateTime.now();
      for (final id in await PeerId.deriveActive(_key(1), now)) {
        expect(
          await index.lookup(id, rosterToken: roster, pubkeys: [_key(1)]),
          equals(_key(1)),
          reason: 'a held or skewed frame must still resolve',
        );
      }
    });

    test('resolves the legacy id, so an older build is still heard', () async {
      final index = PeerIdIndex();
      final legacy = await PeerId.legacy(_key(1));
      expect(
        await index.lookup(legacy, rosterToken: Object(), pubkeys: [_key(1)]),
        equals(_key(1)),
      );
    });

    test('an unknown id resolves to nobody', () async {
      final index = PeerIdIndex();
      final stranger = await PeerId.derive(_key(200), 100);
      expect(
        await index.lookup(stranger, rosterToken: Object(), pubkeys: [_key(1)]),
        isNull,
      );
    });

    test('a changed roster is picked up rather than served stale', () async {
      final index = PeerIdIndex();
      final firstRoster = Object();
      final bobId =
          await PeerId.derive(_key(90), PeerId.epochAt(DateTime.now()));

      expect(
        await index.lookup(bobId, rosterToken: firstRoster, pubkeys: [_key(1)]),
        isNull,
      );
      // Bob joins: a new roster instance must invalidate the table.
      expect(
        await index.lookup(bobId,
            rosterToken: Object(), pubkeys: [_key(1), _key(90)]),
        equals(_key(90)),
      );
    });

    test('clear forgets everything', () async {
      final index = PeerIdIndex();
      final roster = Object();
      final id = await PeerId.derive(_key(1), PeerId.epochAt(DateTime.now()));
      expect(await index.lookup(id, rosterToken: roster, pubkeys: [_key(1)]),
          isNotNull);
      index.clear();
      expect(
        await index.lookup(id, rosterToken: roster, pubkeys: const []),
        isNull,
        reason: 'a cleared index must rebuild from what it is given now',
      );
    });
  });

  group('store-and-forward across a rotation', () {
    test('mail filed under a previous epoch is still handed over', () async {
      final cache = StoreForwardCache();
      final now = DateTime.now();
      final ids = await PeerId.deriveActive(_key(1), now);
      final previousEpochId = ids.first;

      cache.store(
        destHash: previousEpochId,
        frameBytes: Uint8List.fromList([1, 2, 3]),
        origin: Uint8List(8),
        msgId: Uint8List(16),
      );

      // Draining only the current id would strand exactly the oldest mail.
      expect(cache.drainFor(ids[1]), isEmpty);
      expect(cache.drainForAny(ids), hasLength(1));
      expect(cache.size, 0);
    });

    test('drains across several ids without double-counting', () async {
      final cache = StoreForwardCache();
      final ids = await PeerId.deriveActive(_key(1), DateTime.now());
      for (var i = 0; i < ids.length; i++) {
        cache.store(
          destHash: ids[i],
          frameBytes: Uint8List.fromList([i]),
          origin: Uint8List(8),
          msgId: Uint8List(16)..[0] = i,
        );
      }
      // The same id offered twice must not yield its frames twice.
      final drained = cache.drainForAny([...ids, ids.first]);
      expect(drained, hasLength(3));
      expect(cache.size, 0);
    });

    test('an unrelated destination is left alone', () async {
      final cache = StoreForwardCache();
      final mine = await PeerId.deriveActive(_key(1), DateTime.now());
      final theirs = await PeerId.deriveActive(_key(90), DateTime.now());
      cache.store(
        destHash: theirs.first,
        frameBytes: Uint8List.fromList([9]),
        origin: Uint8List(8),
        msgId: Uint8List(16),
      );
      expect(cache.drainForAny(mine), isEmpty);
      expect(cache.size, 1);
    });
  });
}
