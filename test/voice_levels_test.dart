import 'dart:typed_data';

import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List id(int seed) =>
      Uint8List.fromList(List.generate(16, (i) => (i * 11 + seed) & 0xff));

  Uint8List levels(int n) =>
      Uint8List.fromList(List.generate(n, (i) => (i * 3) & 0xff));

  group('VoiceLevels', () {
    test('encode/decode round-trips the id and every bar', () {
      final sent = VoiceLevels(mediaId: id(1), levels: levels(40));
      final back = VoiceLevels.decode(sent.encode());
      expect(back.mediaId, equals(id(1)));
      expect(back.levels, equals(levels(40)));
    });

    test('the encoded body is a version, an id, a count and the bars', () {
      expect(
        VoiceLevels(mediaId: id(2), levels: levels(12)).encode().length,
        2 + 16 + 12,
      );
    });

    test('rides through the inner-payload tag', () {
      final wire = packInnerPayload(
        InnerPayloadType.voiceLevels,
        VoiceLevels(mediaId: id(3), levels: levels(8)).encode(),
      );
      final payload = unpackInnerPayload(wire);
      expect(payload.type, InnerPayloadType.voiceLevels);
      expect(VoiceLevels.decode(payload.body).levels, equals(levels(8)));
    });

    test('a truncated body is refused rather than read past the end', () {
      final good = VoiceLevels(mediaId: id(4), levels: levels(20)).encode();
      for (final cut in [0, 1, 8, 17, good.length - 1]) {
        expect(
          () => VoiceLevels.decode(Uint8List.sublistView(good, 0, cut)),
          throwsFormatException,
          reason: 'a body of $cut bytes is not a voice level frame',
        );
      }
    });

    test('a body longer than its count says is refused', () {
      // Trailing bytes mean this is not the frame that was signed. Exactly the
      // same rule as an album hint, and for the same reason.
      final good = VoiceLevels(mediaId: id(5), levels: levels(6)).encode();
      final padded = Uint8List(good.length + 1)..setRange(0, good.length, good);
      expect(() => VoiceLevels.decode(padded), throwsFormatException);
    });

    test('an unknown version is refused, not guessed at', () {
      final wrong = VoiceLevels(mediaId: id(6), levels: levels(4)).encode()
        ..[0] = 0x02;
      expect(() => VoiceLevels.decode(wrong), throwsFormatException);
    });

    test('a zero count is refused', () {
      // The sender never mints one; a decoder must not have to trust that.
      final zeroed = VoiceLevels(mediaId: id(7), levels: levels(3)).encode()
        ..[17] = 0;
      expect(() => VoiceLevels.decode(zeroed), throwsFormatException);
    });
  });

  group('VoiceLevels.resample', () {
    test('a short recording keeps every reading it had', () {
      final out = VoiceLevels.resample([0.0, 0.5, 1.0]);
      expect(out.length, 3);
      expect(out.first, 0);
      expect(out.last, 255);
      expect(out[1], closeTo(128, 2));
    });

    test('a long recording is folded down to the cap', () {
      final out = VoiceLevels.resample(List<double>.filled(4000, 0.5));
      expect(out.length, VoiceLevels.maxSamples);
      expect(out.every((v) => (v - 128).abs() <= 2), isTrue);
    });

    test('a loud syllable survives being folded', () {
      // Averaged into buckets rather than sampled every nth, because a shout
      // between two picks would otherwise vanish from the drawing entirely.
      final raw = List<double>.filled(1000, 0.0);
      for (var i = 400; i < 410; i++) {
        raw[i] = 1.0;
      }
      final out = VoiceLevels.resample(raw);
      expect(out.any((v) => v > 40), isTrue);
    });

    test('an empty recording still produces something drawable', () {
      expect(VoiceLevels.resample(const []).length, 1);
    });

    test('readings outside 0..1 cannot push a bar off the scale', () {
      final out = VoiceLevels.resample([-3, 0.5, 7]);
      expect(out.first, 0);
      expect(out.last, 255);
    });
  });
}
