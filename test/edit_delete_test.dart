import 'dart:typed_data';

import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List id(int seed) =>
      Uint8List.fromList(List.generate(16, (i) => (i + seed) & 0xff));

  group('MessageEdit', () {
    test('encode/decode round-trips id and text', () {
      final e = MessageEdit(targetMsgId: id(4), text: 'fixed typo 🙂');
      final back = MessageEdit.decode(e.encode());
      expect(back.targetMsgId, equals(id(4)));
      expect(back.text, 'fixed typo 🙂');
    });

    test('rides through the inner-payload tag', () {
      final e = MessageEdit(targetMsgId: id(1), text: 'hi');
      final wire = packInnerPayload(InnerPayloadType.edit, e.encode());
      final unpacked = unpackInnerPayload(wire);
      expect(unpacked.type, InnerPayloadType.edit);
      expect(MessageEdit.decode(unpacked.body).text, 'hi');
    });

    test('empty text is rejected on encode', () {
      expect(
        () => MessageEdit(targetMsgId: id(0), text: '').encode(),
        throwsA(isA<FormatException>()),
      );
    });

    test('a body with only the id (no text) is truncated', () {
      expect(
        () => MessageEdit.decode(Uint8List(MessageEdit.idLen)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a wrong-length id fails the assertion', () {
      expect(
        () => MessageEdit(targetMsgId: Uint8List(8), text: 'x'),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('MessageDelete', () {
    test('encode/decode round-trips the id', () {
      final d = MessageDelete(targetMsgId: id(9));
      expect(MessageDelete.decode(d.encode()).targetMsgId, equals(id(9)));
    });

    test('rides through the inner-payload tag', () {
      final wire = packInnerPayload(
          InnerPayloadType.delete, MessageDelete(targetMsgId: id(2)).encode());
      final unpacked = unpackInnerPayload(wire);
      expect(unpacked.type, InnerPayloadType.delete);
      expect(MessageDelete.decode(unpacked.body).targetMsgId, equals(id(2)));
    });

    test('a body that is not exactly the id is rejected', () {
      expect(() => MessageDelete.decode(Uint8List(15)),
          throwsA(isA<FormatException>()));
      expect(() => MessageDelete.decode(Uint8List(17)),
          throwsA(isA<FormatException>()));
    });
  });
}
