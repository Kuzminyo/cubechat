import 'dart:convert';
import 'dart:typed_data';

import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _id([int fill = 7]) => Uint8List.fromList(
      List<int>.filled(ForwardedFrom.idLen, fill),
    );

void main() {
  test('a name survives the round trip', () {
    final out = ForwardedFrom(targetMsgId: _id(), name: 'Ганна').encode();
    final back = ForwardedFrom.decode(out);

    expect(back.name, 'Ганна');
    expect(back.targetMsgId, _id());
  });

  test('an empty name is legal', () {
    // A peer who has never told us their name is a real case, and refusing the
    // attribution would cost the message its header for no gain.
    final back =
        ForwardedFrom.decode(ForwardedFrom(targetMsgId: _id(), name: '').encode());
    expect(back.name, isEmpty);
  });

  test('the longest allowed name fits', () {
    final name = 'a' * ForwardedFrom.maxNameBytes;
    expect(ForwardedFrom.decode(
      ForwardedFrom(targetMsgId: _id(), name: name).encode(),
    ).name, name);
  });

  test('a name past the cap is refused rather than truncated', () {
    // Truncating would put a name nobody chose above somebody's message.
    expect(
      () => ForwardedFrom(
        targetMsgId: _id(),
        name: 'a' * (ForwardedFrom.maxNameBytes + 1),
      ).encode(),
      throwsFormatException,
    );
  });

  test('multi-byte names are measured in bytes, not characters', () {
    // Cyrillic is two bytes a letter here; a cap counted in characters would
    // let twice the bytes through.
    final name = 'я' * 40;
    expect(utf8.encode(name).length, greaterThan(ForwardedFrom.maxNameBytes));
    expect(
      () => ForwardedFrom(targetMsgId: _id(), name: name).encode(),
      throwsFormatException,
    );
  });

  group('bad bytes are refused, not trusted', () {
    test('truncated', () {
      final good = ForwardedFrom(targetMsgId: _id(), name: 'x').encode();
      expect(
        () => ForwardedFrom.decode(good.sublist(0, good.length - 1)),
        throwsFormatException,
      );
    });

    test('a version this build does not know', () {
      final bytes = ForwardedFrom(targetMsgId: _id(), name: 'x').encode();
      bytes[0] = 9;
      expect(() => ForwardedFrom.decode(bytes), throwsFormatException);
    });

    test('a length that disagrees with the body', () {
      final bytes = ForwardedFrom(targetMsgId: _id(), name: 'abc').encode();
      bytes[1 + ForwardedFrom.idLen] = 99;
      expect(() => ForwardedFrom.decode(bytes), throwsFormatException);
    });

    test('nothing at all', () {
      expect(
        () => ForwardedFrom.decode(Uint8List(0)),
        throwsFormatException,
      );
    });
  });

  test('malformed utf-8 becomes replacement characters, not a refusal', () {
    // A decoder that throws here would let one bad byte take a whole message
    // down; the header degrading is the cheaper failure.
    final bytes = ForwardedFrom(targetMsgId: _id(), name: 'ab').encode();
    bytes[bytes.length - 1] = 0xFF;
    expect(ForwardedFrom.decode(bytes).name, isNotEmpty);
  });

  test('the tag is its own, and not one somebody else is using', () {
    final tags = InnerPayloadType.values.map((v) => v.tag).toList();
    expect(
      tags.where((t) => t == InnerPayloadType.forwardedFrom.tag).length,
      1,
      reason: 'a colliding tag compiles, ships, and breaks installed phones',
    );
  });
}
