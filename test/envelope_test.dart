import 'dart:typed_data';

import 'package:cubechat/core/transport/envelope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TransportEnvelope', () {
    test('roundtrip encode/decode preserves every field', () {
      final origin = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final dest = Uint8List.fromList([9, 10, 11, 12, 13, 14, 15, 16]);
      final id = Uint8List.fromList(List.generate(16, (i) => i + 100));
      final body = Uint8List.fromList(List.generate(40, (i) => i));
      final env = TransportEnvelope(
        originPubkeyHash: origin,
        destPubkeyHash: dest,
        msgId: id,
        ttl: 7,
        body: body,
      );

      final wire = env.encode();
      // Header is fixed-size; total = header + body.
      expect(wire.length, TransportEnvelope.headerLen + body.length);

      final decoded = TransportEnvelope.decode(wire);
      expect(decoded.originPubkeyHash, equals(origin));
      expect(decoded.destPubkeyHash, equals(dest));
      expect(decoded.msgId, equals(id));
      expect(decoded.ttl, 7);
      expect(decoded.body, equals(body));
    });

    test('decrementTtl shrinks by one and clamps at zero', () {
      final env = TransportEnvelope(
        originPubkeyHash: Uint8List(8),
        destPubkeyHash: Uint8List(8),
        msgId: Uint8List(16),
        ttl: 1,
        body: Uint8List(0),
      );
      final once = env.decrementTtl();
      expect(once.ttl, 0);
      final twice = once.decrementTtl();
      expect(twice.ttl, 0); // floor
    });

    test('isBroadcast recognises all-zero destination', () {
      final broadcast = TransportEnvelope(
        originPubkeyHash: Uint8List(8),
        destPubkeyHash: TransportEnvelope.broadcastDest(),
        msgId: Uint8List(16),
        ttl: 7,
        body: Uint8List(0),
      );
      expect(broadcast.isBroadcast, isTrue);

      final addressed = TransportEnvelope(
        originPubkeyHash: Uint8List(8),
        destPubkeyHash: Uint8List.fromList(List.filled(8, 1)),
        msgId: Uint8List(16),
        ttl: 7,
        body: Uint8List(0),
      );
      expect(addressed.isBroadcast, isFalse);
    });

    test('truncated wire bytes throw FormatException', () {
      final shortBytes = Uint8List(TransportEnvelope.headerLen - 1);
      expect(() => TransportEnvelope.decode(shortBytes),
          throwsA(isA<FormatException>()));
    });

    test('newMsgId produces 16 fresh bytes each time', () {
      final a = TransportEnvelope.newMsgId();
      final b = TransportEnvelope.newMsgId();
      expect(a.length, 16);
      expect(b.length, 16);
      expect(a, isNot(equals(b))); // 1 in 2^128 collision chance, ignore
    });
  });
}
