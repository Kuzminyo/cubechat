import 'dart:typed_data';

import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InnerPayload tag', () {
    test('pack/unpack roundtrips a text body', () {
      final body = Uint8List.fromList([72, 101, 108, 108, 111]);
      final wire = packInnerPayload(InnerPayloadType.text, body);
      final unpacked = unpackInnerPayload(wire);
      expect(unpacked.type, InnerPayloadType.text);
      expect(unpacked.body, equals(body));
    });

    test('pack/unpack roundtrips an empty body', () {
      final wire = packInnerPayload(InnerPayloadType.text, Uint8List(0));
      final unpacked = unpackInnerPayload(wire);
      expect(unpacked.type, InnerPayloadType.text);
      expect(unpacked.body, isEmpty);
    });

    test('unknown type byte throws FormatException', () {
      expect(
        () => unpackInnerPayload(Uint8List.fromList([0xFF, 1, 2, 3])),
        throwsA(isA<FormatException>()),
      );
    });

    test('empty buffer throws FormatException', () {
      expect(
        () => unpackInnerPayload(Uint8List(0)),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('ImageChunk', () {
    test('encode/decode preserves every field', () {
      final id = Uint8List.fromList(List.generate(16, (i) => i));
      final data = Uint8List.fromList(List.generate(100, (i) => i & 0xff));
      final c = ImageChunk(
        imageId: id,
        seq: 3,
        total: 7,
        mime: 'image/jpeg',
        data: data,
      );
      final wire = c.encode();
      final decoded = ImageChunk.decode(wire);
      expect(decoded.imageId, equals(id));
      expect(decoded.seq, 3);
      expect(decoded.total, 7);
      expect(decoded.mime, 'image/jpeg');
      expect(decoded.data, equals(data));
    });

    test('encode handles maxDataBytes-sized chunk', () {
      final data =
          Uint8List.fromList(List.generate(ImageChunk.maxDataBytes, (_) => 7));
      final c = ImageChunk(
        imageId: Uint8List(16),
        seq: 0,
        total: 1,
        mime: 'image/png',
        data: data,
      );
      final wire = c.encode();
      final decoded = ImageChunk.decode(wire);
      expect(decoded.data, equals(data));
    });

    test('truncated wire bytes throw FormatException', () {
      expect(
        () => ImageChunk.decode(Uint8List(10)),
        throwsA(isA<FormatException>()),
      );
    });

    test('seq >= total fails the assertion', () {
      expect(
        () => ImageChunk(
          imageId: Uint8List(16),
          seq: 5,
          total: 5,
          mime: 'image/png',
          data: Uint8List(1),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('newImageId mints distinct ids', () {
      final a = ImageChunk.newImageId();
      final b = ImageChunk.newImageId();
      expect(a.length, ImageChunk.idLen);
      expect(b.length, ImageChunk.idLen);
      expect(a, isNot(equals(b)));
    });

    test('UTF-8 mime survives the round-trip', () {
      final c = ImageChunk(
        imageId: Uint8List(16),
        seq: 0,
        total: 1,
        mime: 'image/jpeg; charset=Ω',
        data: Uint8List(2),
      );
      final decoded = ImageChunk.decode(c.encode());
      expect(decoded.mime, 'image/jpeg; charset=Ω');
    });
  });

  group('AudioChunk', () {
    test('encode/decode preserves every field', () {
      final id = Uint8List.fromList(List.generate(16, (i) => i + 30));
      final data =
          Uint8List.fromList(List.generate(80, (i) => (i * 3) & 0xff));
      final c = AudioChunk(
        audioId: id,
        seq: 2,
        total: 4,
        durationMs: 7500,
        mime: 'audio/aac',
        data: data,
      );
      final decoded = AudioChunk.decode(c.encode());
      expect(decoded.audioId, equals(id));
      expect(decoded.seq, 2);
      expect(decoded.total, 4);
      expect(decoded.durationMs, 7500);
      expect(decoded.mime, 'audio/aac');
      expect(decoded.data, equals(data));
    });

    test('large durationMs (close to u32 max) survives', () {
      final c = AudioChunk(
        audioId: Uint8List(16),
        seq: 0,
        total: 1,
        durationMs: 0xFFFFFF00,
        mime: 'audio/aac',
        data: Uint8List(2),
      );
      expect(AudioChunk.decode(c.encode()).durationMs, 0xFFFFFF00);
    });

    test('truncated wire bytes throw FormatException', () {
      expect(
        () => AudioChunk.decode(Uint8List(10)),
        throwsA(isA<FormatException>()),
      );
    });

    test('newAudioId mints distinct ids', () {
      expect(AudioChunk.newAudioId(),
          isNot(equals(AudioChunk.newAudioId())));
    });
  });
}
