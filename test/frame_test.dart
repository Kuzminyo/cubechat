import 'dart:typed_data';

import 'package:cubechat/core/transport/frame.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(int seed, int len) =>
    Uint8List.fromList(List.generate(len, (i) => (seed + i) & 0xFF));

void main() {
  group('FrameType', () {
    test('fromByte maps every known type back to itself', () {
      for (final t in FrameType.values) {
        expect(FrameType.fromByte(t.value), t);
      }
    });

    test('fromByte returns null for an unknown byte', () {
      expect(FrameType.fromByte(0x00), isNull);
      expect(FrameType.fromByte(0x99), isNull);
      expect(FrameType.fromByte(0xFF), isNull);
    });
  });

  group('Frame', () {
    test('encode lays out [type | payload]', () {
      final frame = Frame(type: FrameType.transport, payload: _bytes(1, 4));
      final wire = frame.encode();
      expect(wire.length, 5);
      expect(wire[0], FrameType.transport.value);
      expect(wire.sublist(1), _bytes(1, 4));
    });

    test('encode/decode round-trips each frame type', () {
      for (final t in FrameType.values) {
        final payload = _bytes(t.value, 12);
        final decoded = Frame.decode(Frame(type: t, payload: payload).encode());
        expect(decoded.type, t);
        expect(decoded.payload, payload);
      }
    });

    test('round-trips a zero-length payload (e.g. reset)', () {
      final frame = Frame(type: FrameType.reset, payload: Uint8List(0));
      final wire = frame.encode();
      expect(wire.length, 1);
      final decoded = Frame.decode(wire);
      expect(decoded.type, FrameType.reset);
      expect(decoded.payload, isEmpty);
    });

    test('decode of empty bytes throws FrameDecodeException', () {
      expect(
        () => Frame.decode(Uint8List(0)),
        throwsA(isA<FrameDecodeException>()),
      );
    });

    test('decode of an unknown type byte throws FrameDecodeException', () {
      final wire = Uint8List.fromList([0x99, 1, 2, 3]);
      expect(
        () => Frame.decode(wire),
        throwsA(isA<FrameDecodeException>()),
      );
    });

    test('decoded payload is a copy — mutating the source does not leak in', () {
      final source = Uint8List.fromList([FrameType.transport.value, 10, 20, 30]);
      final decoded = Frame.decode(source);
      source[1] = 0xFF;
      expect(decoded.payload[0], 10);
    });

    test('encoded buffer is independent of the source payload', () {
      final payload = _bytes(5, 4);
      final frame = Frame(type: FrameType.transport, payload: payload);
      final wire = frame.encode();
      payload[0] = 0xFF;
      // The already-encoded buffer must not reflect a later payload mutation.
      expect(wire[1], 5);
    });
  });
}
