import 'dart:typed_data';

import 'package:cubechat/core/transport/call_signal.dart';
import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List id(int seed) =>
      Uint8List.fromList(List.generate(callIdLen, (i) => (i + seed) & 0xff));

  group('CallSignal', () {
    test('an invite round-trips its sdp and the moment it was sent', () {
      final signal = CallSignal.invite(
        callId: id(3),
        sdp: 'v=0\r\no=- 1 2 IN IP4 0.0.0.0\r\n',
        sentAtMs: 1789000000123,
      );
      final back = CallSignal.decode(signal.encode());
      expect(back.kind, CallSignalKind.invite);
      expect(back.callId, equals(id(3)));
      expect(back.sdp, 'v=0\r\no=- 1 2 IN IP4 0.0.0.0\r\n');
      expect(back.sentAtMs, 1789000000123);
    });

    test('a timestamp past the 32-bit mark survives the round trip', () {
      // Milliseconds since the epoch need 41 bits. Encoding them with
      // `setUint64` would throw on the web build, and shifting by 32 is wrong
      // there too, so the two halves are cut arithmetically. This is the test
      // that catches somebody "simplifying" that back to a shift.
      final signal = CallSignal.invite(
        callId: id(0),
        sdp: 'x',
        sentAtMs: 0x1_0000_0001,
      );
      expect(CallSignal.decode(signal.encode()).sentAtMs, 0x1_0000_0001);
    });

    test('an accept carries sdp and nothing else', () {
      final back = CallSignal.decode(
        CallSignal.accept(callId: id(1), sdp: 'answer').encode(),
      );
      expect(back.kind, CallSignalKind.accept);
      expect(back.sdp, 'answer');
      expect(back.sentAtMs, isNull);
      expect(back.reason, isNull);
    });

    test('ringing and busy carry an id and an empty body', () {
      for (final signal in [CallSignal.ringing(id(2)), CallSignal.busy(id(2))]) {
        final back = CallSignal.decode(signal.encode());
        expect(back.callId, equals(id(2)));
        expect(back.sdp, isNull);
      }
    });

    test('a hangup round-trips its reason', () {
      final back = CallSignal.decode(
        CallSignal.hangup(callId: id(5), reason: CallEndReason.noAnswer)
            .encode(),
      );
      expect(back.kind, CallSignalKind.hangup);
      expect(back.reason, CallEndReason.noAnswer);
    });

    test('rides through the inner-payload tag', () {
      final wire = packInnerPayload(
        InnerPayloadType.callSignal,
        CallSignal.ringing(id(7)).encode(),
      );
      final unpacked = unpackInnerPayload(wire);
      expect(unpacked.type, InnerPayloadType.callSignal);
      expect(CallSignal.decode(unpacked.body).callId, equals(id(7)));
    });

    test('the tag byte is 0xE7 and nothing else claims it', () {
      expect(InnerPayloadType.callSignal.tag, 0xE7);
      final sameTag = InnerPayloadType.values
          .where((v) => v.tag == 0xE7)
          .toList(growable: false);
      expect(sameTag, hasLength(1));
    });

    test('a truncated buffer is rejected rather than read', () {
      final whole = CallSignal.ringing(id(1)).encode();
      for (var cut = 0; cut < whole.length; cut++) {
        expect(
          () => CallSignal.decode(Uint8List.sublistView(whole, 0, cut)),
          throwsA(isA<FormatException>()),
          reason: 'a buffer cut at $cut must not decode',
        );
      }
    });

    test('a body shorter than its own length field is rejected', () {
      final whole = CallSignal.accept(callId: id(1), sdp: 'answer').encode();
      whole[2 + callIdLen] = 0xff;
      expect(
        () => CallSignal.decode(whole),
        throwsA(isA<FormatException>()),
      );
    });

    test('an unknown version is rejected', () {
      final whole = CallSignal.ringing(id(1)).encode();
      whole[0] = 0x02;
      expect(() => CallSignal.decode(whole), throwsA(isA<FormatException>()));
    });

    test('an unknown kind is rejected', () {
      final whole = CallSignal.ringing(id(1)).encode();
      whole[1] = 0x7f;
      expect(() => CallSignal.decode(whole), throwsA(isA<FormatException>()));
    });

    test('an invite with no sdp is rejected', () {
      final whole = CallSignal.invite(
        callId: id(1),
        sdp: 'x',
        sentAtMs: 1,
      ).encode();
      // Cut the sdp byte off, and shorten the declared length to match, so the
      // only thing wrong is that an invite says nothing.
      final trimmed = Uint8List.sublistView(whole, 0, whole.length - 1);
      trimmed[3 + callIdLen] = 8;
      expect(
        () => CallSignal.decode(Uint8List.fromList(trimmed)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a wrong-length call id is refused on encode', () {
      expect(
        () => CallSignal.ringing(Uint8List(8)).encode(),
        throwsA(isA<FormatException>()),
      );
    });

    test('an unknown reason from a newer build still ends the call', () {
      // Losing the label is survivable; a call that will not hang up is not.
      final whole = CallSignal.hangup(
        callId: id(1),
        reason: CallEndReason.hungUp,
      ).encode();
      whole[whole.length - 1] = 0x7e;
      expect(CallSignal.decode(whole).reason, CallEndReason.hungUp);
    });
  });
}
