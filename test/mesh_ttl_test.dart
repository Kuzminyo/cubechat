import 'dart:typed_data';

import 'package:cubechat/core/transport/envelope.dart';
import 'package:flutter_test/flutter_test.dart';

TransportEnvelope _env({required int ttl}) => TransportEnvelope(
      originPubkeyHash: Uint8List(TransportEnvelope.hashLen),
      destPubkeyHash: TransportEnvelope.broadcastDest(),
      msgId: TransportEnvelope.newMsgId(),
      ttl: ttl,
      body: Uint8List.fromList([1, 2, 3]),
    );

void main() {
  group('density-scaled hop budget', () {
    test('a lone node spends the full depth', () {
      expect(
        TransportEnvelope.ttlForLinkCount(0),
        TransportEnvelope.defaultTtl,
      );
      expect(
        TransportEnvelope.ttlForLinkCount(1),
        TransportEnvelope.defaultTtl,
      );
    });

    test('a sparse chain keeps the full depth — it is what reaches the end',
        () {
      expect(
        TransportEnvelope.ttlForLinkCount(2),
        TransportEnvelope.defaultTtl,
      );
      expect(
        TransportEnvelope.ttlForLinkCount(5),
        TransportEnvelope.defaultTtl,
      );
    });

    test('a dense cluster cuts the budget, where flooding costs most', () {
      expect(
        TransportEnvelope.ttlForLinkCount(TransportEnvelope.denseLinkThreshold),
        TransportEnvelope.denseTtl,
      );
      expect(TransportEnvelope.ttlForLinkCount(40), TransportEnvelope.denseTtl);
    });

    test('the cut is a reduction, never an increase', () {
      for (var links = 0; links <= 50; links++) {
        expect(
          TransportEnvelope.ttlForLinkCount(links),
          lessThanOrEqualTo(TransportEnvelope.defaultTtl),
        );
        expect(
          TransportEnvelope.ttlForLinkCount(links),
          greaterThan(0),
          reason: 'a budget of zero would mean nothing is ever relayed',
        );
      }
    });

    test('the budget is monotonic in density', () {
      var previous = TransportEnvelope.ttlForLinkCount(0);
      for (var links = 1; links <= 50; links++) {
        final current = TransportEnvelope.ttlForLinkCount(links);
        expect(
          current,
          lessThanOrEqualTo(previous),
          reason: 'more links must never buy more hops',
        );
        previous = current;
      }
    });
  });

  group('relay ttl arithmetic', () {
    test('withTtl replaces the budget and leaves routing untouched', () {
      final env = _env(ttl: 7);
      final capped = env.withTtl(TransportEnvelope.denseTtl);
      expect(capped.ttl, TransportEnvelope.denseTtl);
      expect(capped.msgId, equals(env.msgId));
      expect(capped.originPubkeyHash, equals(env.originPubkeyHash));
      expect(capped.destPubkeyHash, equals(env.destPubkeyHash));
      expect(capped.body, equals(env.body));
    });

    test('a full-depth frame entering a crowd is capped on the way out', () {
      // What _forwardEnvelope does: decrement, then apply the local ceiling.
      final arriving = _env(ttl: TransportEnvelope.defaultTtl);
      var relayed = arriving.decrementTtl();
      expect(relayed.ttl, 6);

      final cap = TransportEnvelope.ttlForLinkCount(9); // dense relay
      if (relayed.ttl > cap) relayed = relayed.withTtl(cap);
      expect(relayed.ttl, TransportEnvelope.denseTtl);
    });

    test('a sparse relay passes the decremented budget through untouched', () {
      final arriving = _env(ttl: TransportEnvelope.defaultTtl);
      var relayed = arriving.decrementTtl();
      final cap = TransportEnvelope.ttlForLinkCount(2);
      if (relayed.ttl > cap) relayed = relayed.withTtl(cap);
      expect(relayed.ttl, 6, reason: 'nothing to cap in a chain');
    });

    test('the cap never inflates a deliberately short budget', () {
      // A relay introduction rides at ttl 1 precisely so the recipient does not
      // re-broadcast it (see _announceOverNostrTo). A dense node must not hand
      // it more hops than it was given.
      final introduction = _env(ttl: 1);
      var relayed = introduction.decrementTtl();
      expect(relayed.ttl, 0);

      final cap = TransportEnvelope.ttlForLinkCount(20);
      if (relayed.ttl > cap) relayed = relayed.withTtl(cap);
      expect(relayed.ttl, 0, reason: 'exhausted stays exhausted');
    });

    test('a capped frame still survives the encode/decode round trip', () {
      final capped = _env(ttl: TransportEnvelope.defaultTtl)
          .withTtl(TransportEnvelope.denseTtl);
      final decoded = TransportEnvelope.decode(capped.encode());
      expect(decoded.ttl, TransportEnvelope.denseTtl);
      expect(decoded.body, equals(capped.body));
    });
  });
}
