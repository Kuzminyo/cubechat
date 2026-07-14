import 'dart:typed_data';

import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List id(int seed) =>
      Uint8List.fromList(List.generate(16, (i) => (i + seed) & 0xff));

  group('ReadReceipt', () {
    test('encode/decode preserves status + ids', () {
      final r = ReadReceipt(
        status: ReceiptStatus.read,
        msgIds: [id(1), id(50), id(200)],
      );
      final back = ReadReceipt.decode(r.encode());
      expect(back.status, ReceiptStatus.read);
      expect(back.msgIds.length, 3);
      expect(back.msgIds[0], equals(id(1)));
      expect(back.msgIds[1], equals(id(50)));
      expect(back.msgIds[2], equals(id(200)));
    });

    test('single-id receipt round-trips', () {
      final back = ReadReceipt.decode(
        ReadReceipt(status: ReceiptStatus.read, msgIds: [id(9)]).encode(),
      );
      expect(back.msgIds.single, equals(id(9)));
    });

    test('rides through the inner-payload tag', () {
      final r = ReadReceipt(status: ReceiptStatus.read, msgIds: [id(3)]);
      final wire = packInnerPayload(InnerPayloadType.receipt, r.encode());
      final unpacked = unpackInnerPayload(wire);
      expect(unpacked.type, InnerPayloadType.receipt);
      expect(ReadReceipt.decode(unpacked.body).msgIds.single, equals(id(3)));
    });

    test('truncated id list throws', () {
      final wire = Uint8List.fromList([ReceiptStatus.read.tag, 2, 1, 2, 3]);
      expect(
        () => ReadReceipt.decode(wire),
        throwsA(isA<FormatException>()),
      );
    });

    test('unknown status byte throws', () {
      expect(
        () => ReadReceipt.decode(Uint8List.fromList([0x99, 0])),
        throwsA(isA<FormatException>()),
      );
    });

    test('empty id list fails the assertion', () {
      expect(
        () => ReadReceipt(status: ReceiptStatus.read, msgIds: const []),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('Reaction', () {
    test('encode/decode preserves op, emoji, target', () {
      final r = Reaction(op: ReactionOp.add, emoji: '🔥', targetMsgId: id(7));
      final back = Reaction.decode(r.encode());
      expect(back.op, ReactionOp.add);
      expect(back.emoji, '🔥');
      expect(back.targetMsgId, equals(id(7)));
    });

    test('remove op round-trips', () {
      final back = Reaction.decode(
        Reaction(op: ReactionOp.remove, emoji: '👍', targetMsgId: id(2))
            .encode(),
      );
      expect(back.op, ReactionOp.remove);
      expect(back.emoji, '👍');
    });

    test('rides through the inner-payload tag', () {
      final r = Reaction(op: ReactionOp.add, emoji: '❤️', targetMsgId: id(4));
      final wire = packInnerPayload(InnerPayloadType.reaction, r.encode());
      final unpacked = unpackInnerPayload(wire);
      expect(unpacked.type, InnerPayloadType.reaction);
      final back = Reaction.decode(unpacked.body);
      expect(back.emoji, '❤️');
      expect(back.targetMsgId, equals(id(4)));
    });

    test('empty emoji throws on encode', () {
      expect(
        () => Reaction(op: ReactionOp.add, emoji: '', targetMsgId: id(1))
            .encode(),
        throwsA(isA<FormatException>()),
      );
    });

    test('truncated body throws', () {
      expect(
        () => Reaction.decode(Uint8List.fromList([ReactionOp.add.tag])),
        throwsA(isA<FormatException>()),
      );
    });

    test('wrong target-id length fails the assertion', () {
      expect(
        () => Reaction(
          op: ReactionOp.add,
          emoji: '👍',
          targetMsgId: Uint8List(8),
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('MessageEdit', () {
    test('encode/decode round-trips target and text', () {
      final e = MessageEdit(targetMsgId: id(5), text: 'виправлений текст');
      final back = MessageEdit.decode(e.encode());
      expect(back.targetMsgId, equals(id(5)));
      expect(back.text, 'виправлений текст');
    });

    test('rides through the inner-payload tag', () {
      final e = MessageEdit(targetMsgId: id(2), text: 'ok');
      final wire = packInnerPayload(InnerPayloadType.edit, e.encode());
      final unpacked = unpackInnerPayload(wire);
      expect(unpacked.type, InnerPayloadType.edit);
      expect(MessageEdit.decode(unpacked.body).text, 'ok');
    });

    test('a one-character edit survives (text runs to the end)', () {
      final back = MessageEdit.decode(
        MessageEdit(targetMsgId: id(1), text: 'x').encode(),
      );
      expect(back.text, 'x');
      expect(back.targetMsgId, equals(id(1)));
    });

    test('empty text is rejected on encode', () {
      expect(
        () => MessageEdit(targetMsgId: id(1), text: '').encode(),
        throwsA(isA<FormatException>()),
      );
    });

    test('a body with only the id and no text is truncated', () {
      expect(
        () => MessageEdit.decode(Uint8List(MessageEdit.idLen)),
        throwsA(isA<FormatException>()),
      );
    });

    test('wrong target-id length fails the assertion', () {
      expect(
        () => MessageEdit(targetMsgId: Uint8List(4), text: 'x'),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
