import 'dart:convert';
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

    test('seq >= total throws FormatException at runtime', () {
      expect(
        () => ImageChunk(
          imageId: Uint8List(16),
          seq: 5,
          total: 5,
          mime: 'image/png',
          data: Uint8List(1),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('decode rejects zero total and oversized image data', () {
      final zeroTotal = Uint8List(ImageChunk.idLen + 2 + 2 + 1 + 2);
      zeroTotal[ImageChunk.idLen + 3] = 0; // total low byte remains zero
      expect(
          () => ImageChunk.decode(zeroTotal), throwsA(isA<FormatException>()));

      final tooLarge = Uint8List(
        ImageChunk.idLen + 2 + 2 + 1 + 2 + ImageChunk.maxDataBytes + 1,
      );
      var c = ImageChunk.idLen;
      tooLarge[c++] = 0;
      tooLarge[c++] = 0; // seq
      tooLarge[c++] = 0;
      tooLarge[c++] = 1; // total
      tooLarge[c++] = 0; // mime len
      final len = ImageChunk.maxDataBytes + 1;
      tooLarge[c++] = (len >> 8) & 0xff;
      tooLarge[c++] = len & 0xff;
      expect(
          () => ImageChunk.decode(tooLarge), throwsA(isA<FormatException>()));
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
      final data = Uint8List.fromList(List.generate(80, (i) => (i * 3) & 0xff));
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

    test('decode rejects zero total and oversized audio data', () {
      final zeroTotal = Uint8List(AudioChunk.idLen + 2 + 2 + 4 + 1 + 2);
      expect(
          () => AudioChunk.decode(zeroTotal), throwsA(isA<FormatException>()));

      final tooLarge = Uint8List(
        AudioChunk.idLen + 2 + 2 + 4 + 1 + 2 + AudioChunk.maxDataBytes + 1,
      );
      var c = AudioChunk.idLen;
      tooLarge[c++] = 0;
      tooLarge[c++] = 0; // seq
      tooLarge[c++] = 0;
      tooLarge[c++] = 1; // total
      c += 4; // duration
      tooLarge[c++] = 0; // mime len
      final len = AudioChunk.maxDataBytes + 1;
      tooLarge[c++] = (len >> 8) & 0xff;
      tooLarge[c++] = len & 0xff;
      expect(
          () => AudioChunk.decode(tooLarge), throwsA(isA<FormatException>()));
    });

    test('newAudioId mints distinct ids', () {
      expect(AudioChunk.newAudioId(), isNot(equals(AudioChunk.newAudioId())));
    });
  });

  group('text padding', () {
    Uint8List u(String s) => Uint8List.fromList(s.codeUnits);

    test('short text is padded to the 48-byte bucket', () {
      final padded = padTextPayload(u('ok'));
      expect(padded.length, 48);
      expect(unpadTextPayload(padded), equals(u('ok')));
    });

    test('empty text still pads to the bucket', () {
      final padded = padTextPayload(Uint8List(0));
      expect(padded.length, 48);
      expect(unpadTextPayload(padded), isEmpty);
    });

    test('two short messages of different length share one padded size', () {
      expect(padTextPayload(u('a')).length,
          padTextPayload(u('hello there')).length);
    });

    test('long text is not padded (just the length prefix)', () {
      final long = u('x' * 100);
      final padded = padTextPayload(long);
      expect(padded.length, 2 + 100);
      expect(unpadTextPayload(padded), equals(long));
    });

    test('UTF-8 multibyte text round-trips', () {
      final utf8Bytes = Uint8List.fromList(utf8.encode('Привет 🦊'));
      final padded = padTextPayload(utf8Bytes);
      expect(unpadTextPayload(padded), equals(utf8Bytes));
    });

    test('unpadTextPayload tolerates a legacy unprefixed body', () {
      // Old sender: body is raw UTF-8 with no 2-byte length prefix. The
      // declared length (first two bytes) will overrun, so we fall back
      // to returning the whole body unchanged.
      final legacy = Uint8List.fromList([0xFF, 0xFF, 1, 2, 3]);
      expect(unpadTextPayload(legacy), equals(legacy));
    });
  });

  group('MediaManifest', () {
    test('encode/decode preserves every field', () {
      final m = MediaManifest(
        mediaId: Uint8List.fromList(List.generate(16, (i) => i + 1)),
        kind: MediaKind.image,
        total: 359,
        durationMs: 0,
        mime: 'image/jpeg',
        sha256: Uint8List.fromList(List.generate(32, (i) => i)),
      );
      final wire = m.encode();
      final back = MediaManifest.decode(wire);
      expect(back.mediaId, equals(m.mediaId));
      expect(back.kind, MediaKind.image);
      expect(back.total, 359);
      expect(back.durationMs, 0);
      expect(back.mime, 'image/jpeg');
      expect(back.sha256, equals(m.sha256));
    });

    test('audio manifest carries durationMs', () {
      final m = MediaManifest(
        mediaId: Uint8List(16),
        kind: MediaKind.audio,
        total: 120,
        durationMs: 7500,
        mime: 'audio/aac',
        sha256: Uint8List(32),
      );
      final back = MediaManifest.decode(m.encode());
      expect(back.kind, MediaKind.audio);
      expect(back.durationMs, 7500);
    });

    test('truncated wire bytes throw FormatException', () {
      expect(
        () => MediaManifest.decode(Uint8List(10)),
        throwsA(isA<FormatException>()),
      );
    });

    test('unknown version byte throws', () {
      final bad = Uint8List(1 + 16 + 1 + 2 + 4 + 1 + 32);
      bad[0] = 0x99;
      expect(
        () => MediaManifest.decode(bad),
        throwsA(isA<FormatException>()),
      );
    });

    test('unknown kind tag throws', () {
      final m = MediaManifest(
        mediaId: Uint8List(16),
        kind: MediaKind.image,
        total: 1,
        mime: '',
        sha256: Uint8List(32),
      );
      final wire = m.encode();
      wire[1 + 16] = 0xEE; // garbage in the kind slot
      expect(
        () => MediaManifest.decode(wire),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
