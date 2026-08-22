import 'dart:typed_data';

import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List id(int seed) =>
      Uint8List.fromList(List.generate(16, (i) => (i * 7 + seed) & 0xff));

  List<Uint8List> ids(int n) => [for (var i = 0; i < n; i++) id(i + 1)];

  group('AlbumHint', () {
    test('encode/decode round-trips the batch in order', () {
      final hint = AlbumHint(mediaIds: ids(5));
      final back = AlbumHint.decode(hint.encode());
      expect(back.mediaIds.length, 5);
      for (var i = 0; i < 5; i++) {
        expect(back.mediaIds[i], equals(ids(5)[i]));
      }
    });

    test('the encoded body is exactly two bytes plus the ids', () {
      expect(AlbumHint(mediaIds: ids(3)).encode().length, 2 + 3 * 16);
    });

    test('rides through the inner-payload tag', () {
      final wire = packInnerPayload(
        InnerPayloadType.albumHint,
        AlbumHint(mediaIds: ids(2)).encode(),
      );
      final unpacked = unpackInnerPayload(wire);
      expect(unpacked.type, InnerPayloadType.albumHint);
      expect(AlbumHint.decode(unpacked.body).mediaIds.length, 2);
    });

    // The compatibility property the whole design rests on: a build that
    // predates this tag drops the hint frame and nothing else. If the byte
    // collided with a payload an old build already knows, that build would
    // hand these bytes to the wrong decoder instead.
    test('its tag byte is not one another payload already uses', () {
      final others = InnerPayloadType.values
          .where((t) => t != InnerPayloadType.albumHint)
          .map((t) => t.tag);
      expect(others, isNot(contains(InnerPayloadType.albumHint.tag)));
      expect(
        InnerPayloadType.fromByte(InnerPayloadType.albumHint.tag),
        InnerPayloadType.albumHint,
      );
    });

    test('a full batch of maxPhotos round-trips', () {
      final hint = AlbumHint(mediaIds: ids(AlbumHint.maxPhotos));
      expect(
        AlbumHint.decode(hint.encode()).mediaIds.length,
        AlbumHint.maxPhotos,
      );
    });

    group('rejects', () {
      test('an empty body', () {
        expect(
          () => AlbumHint.decode(Uint8List(0)),
          throwsA(isA<FormatException>()),
        );
      });

      test('an unknown version byte', () {
        final bytes = AlbumHint(mediaIds: ids(2)).encode()..[0] = 0x02;
        expect(
          () => AlbumHint.decode(bytes),
          throwsA(isA<FormatException>()),
        );
      });

      test('a count of one, which is a photo and not an album', () {
        final bytes = Uint8List.fromList([AlbumHint.version1, 1, ...id(1)]);
        expect(
          () => AlbumHint.decode(bytes),
          throwsA(isA<FormatException>()),
        );
      });

      test('a count past maxPhotos', () {
        final bytes = Uint8List(2 + (AlbumHint.maxPhotos + 1) * 16)
          ..[0] = AlbumHint.version1
          ..[1] = AlbumHint.maxPhotos + 1;
        expect(
          () => AlbumHint.decode(bytes),
          throwsA(isA<FormatException>()),
        );
      });

      test('a count that overruns the body', () {
        final bytes =
            Uint8List.fromList([AlbumHint.version1, 4, ...id(1), ...id(2)]);
        expect(
          () => AlbumHint.decode(bytes),
          throwsA(isA<FormatException>()),
        );
      });

      // Not "at least the ids": a padded hint is not the frame that was
      // signed, and the manifest decoder refuses trailing bytes for the same
      // reason.
      test('trailing bytes after the last id', () {
        final bytes = Uint8List.fromList(
          [...AlbumHint(mediaIds: ids(2)).encode(), 0x00],
        );
        expect(
          () => AlbumHint.decode(bytes),
          throwsA(isA<FormatException>()),
        );
      });

      test('a wrong-length id fails the assertion', () {
        expect(
          () => AlbumHint(mediaIds: [id(1), Uint8List(15)]),
          throwsA(isA<AssertionError>()),
        );
      });

      test('a single id fails the assertion', () {
        expect(
          () => AlbumHint(mediaIds: [id(1)]),
          throwsA(isA<AssertionError>()),
        );
      });
    });
  });
}
