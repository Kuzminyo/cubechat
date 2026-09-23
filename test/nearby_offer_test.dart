import 'dart:convert';
import 'dart:typed_data';

import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:cubechat/core/transport/nearby_offer.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _id(int seed) =>
    Uint8List.fromList(List.generate(nearbyIdLen, (i) => (seed + i) & 0xFF));

NearbyOfferFile _file(
  int seed, {
  String name = 'photo.jpg',
  String mime = 'image/jpeg',
  int size = 1234,
}) =>
    NearbyOfferFile(mediaId: _id(seed), size: size, name: name, mime: mime);

NearbyOffer _offer(int count) => NearbyOffer(
      transferId: _id(200),
      files: [for (var i = 0; i < count; i++) _file(i * 17 + 1)],
    );

void main() {
  group('tag bytes', () {
    test('nearbyOffer is 0xE8 and nearbyAnswer is 0xE9', () {
      expect(InnerPayloadType.nearbyOffer.tag, 0xE8);
      expect(InnerPayloadType.nearbyAnswer.tag, 0xE9);
      expect(InnerPayloadType.fromByte(0xE8), InnerPayloadType.nearbyOffer);
      expect(InnerPayloadType.fromByte(0xE9), InnerPayloadType.nearbyAnswer);
    });

    // A colliding byte compiles, passes every other test and breaks phones
    // that already have the app — see the wire-protocol skill.
    test('no two inner payload types share a byte', () {
      final tags = InnerPayloadType.values.map((v) => v.tag).toList();
      expect(tags.toSet().length, tags.length);
    });
  });

  group('NearbyOffer', () {
    test('round-trips one file', () {
      final offer = NearbyOffer(
        transferId: _id(9),
        flags: 0,
        files: [_file(1, name: 'відпустка.mp4', mime: 'video/mp4', size: 42)],
      );
      final back = NearbyOffer.decode(offer.encode());
      expect(back.transferId, _id(9));
      expect(back.flags, 0);
      expect(back.files.single.mediaId, _id(1));
      expect(back.files.single.name, 'відпустка.mp4');
      expect(back.files.single.mime, 'video/mp4');
      expect(back.files.single.size, 42);
      expect(back.totalBytes, 42);
    });

    test('round-trips fifty files and a size past 4 GiB', () {
      const big = 5 * 1024 * 1024 * 1024;
      final offer = NearbyOffer(
        transferId: _id(1),
        files: [for (var i = 0; i < 50; i++) _file(i * 3 + 5, size: big + i)],
      );
      final back = NearbyOffer.decode(offer.encode());
      expect(back.files, hasLength(50));
      expect(back.files.last.size, big + 49);
    });

    test('keeps a 255-byte name and cuts a longer one on a character', () {
      final exact = 'a' * 255;
      expect(
        NearbyOffer.decode(
          NearbyOffer(transferId: _id(1), files: [_file(1, name: exact)])
              .encode(),
        ).files.single.name,
        exact,
      );
      final long = 'я' * 200; // 400 bytes of UTF-8
      final back = NearbyOffer.decode(
        NearbyOffer(transferId: _id(1), files: [_file(1, name: long)]).encode(),
      );
      expect(
        utf8.encode(back.files.single.name).length,
        lessThanOrEqualTo(255),
      );
      expect(back.files.single.name, 'я' * 127);
    });

    test('refuses to encode no files or more than fifty', () {
      expect(
        () => NearbyOffer(transferId: _id(1), files: const []).encode(),
        throwsArgumentError,
      );
      expect(() => _offer(51).encode(), throwsArgumentError);
    });

    group('decode rejects', () {
      late Uint8List good;
      setUp(() => good = _offer(2).encode());

      test('a truncated body', () {
        expect(
          () => NearbyOffer.decode(good.sublist(0, good.length - 1)),
          throwsFormatException,
        );
      });

      test('a trailing byte', () {
        expect(
          () => NearbyOffer.decode(Uint8List.fromList([...good, 0])),
          throwsFormatException,
        );
      });

      test('another version', () {
        final bad = Uint8List.fromList(good)..[0] = 0x02;
        expect(() => NearbyOffer.decode(bad), throwsFormatException);
      });

      test('zero files and fifty-one files', () {
        const countAt = 1 + nearbyIdLen + 1;
        expect(
          () => NearbyOffer.decode(Uint8List.fromList(good)..[countAt] = 0),
          throwsFormatException,
        );
        expect(
          () => NearbyOffer.decode(Uint8List.fromList(good)..[countAt] = 51),
          throwsFormatException,
        );
      });

      test('a name length running past the end', () {
        const nameLenAt = 1 + nearbyIdLen + 1 + 1 + nearbyIdLen + 8;
        final bad = Uint8List.fromList(good)..[nameLenAt] = 255;
        expect(() => NearbyOffer.decode(bad), throwsFormatException);
      });

      // [0]=ver [1..16]=tid [17]=flags [18]=count [19..34]=mediaId
      // [35..42]=size [43]=nameLen [44]=name [45]=mimeLen [46]=mime
      Uint8List oneFile() => NearbyOffer(
            transferId: _id(3),
            files: [_file(4, name: 'n', mime: 'm')],
          ).encode();

      test('a mime that is not ASCII', () {
        expect(
          () => NearbyOffer.decode(oneFile()..[46] = 0xC3),
          throwsFormatException,
        );
      });

      test('a name that is not UTF-8', () {
        expect(
          () => NearbyOffer.decode(oneFile()..[44] = 0xFF),
          throwsFormatException,
        );
      });

      test('a size beyond what a Dart int holds everywhere', () {
        final bad = oneFile();
        for (var i = 35; i < 39; i++) {
          bad[i] = 0xFF;
        }
        expect(() => NearbyOffer.decode(bad), throwsFormatException);
      });

      test('the same media id twice', () {
        final twice =
            NearbyOffer(transferId: _id(1), files: [_file(1), _file(1)]);
        expect(() => NearbyOffer.decode(twice.encode()), throwsFormatException);
      });
    });
  });

  group('NearbyAnswer', () {
    test('round-trips every kind and reason', () {
      for (final kind in NearbyAnswerKind.values) {
        for (final reason in NearbyDeclineReason.values) {
          final back = NearbyAnswer.decode(
            NearbyAnswer(transferId: _id(7), kind: kind, reason: reason)
                .encode(),
          );
          expect(back.transferId, _id(7));
          expect(back.kind, kind);
          expect(back.reason, reason);
        }
      }
    });

    test('is exactly 19 bytes', () {
      expect(
        NearbyAnswer(transferId: _id(1), kind: NearbyAnswerKind.seen)
            .encode()
            .length,
        19,
      );
    });

    // A newer build inventing a reason must still be able to say no to this
    // one; losing the label costs a word, refusing the frame costs the answer.
    test('an unknown reason reads as the person declining', () {
      final bytes = NearbyAnswer(
        transferId: _id(1),
        kind: NearbyAnswerKind.declined,
        reason: NearbyDeclineReason.busy,
      ).encode()
        ..[18] = 0x7F;
      expect(NearbyAnswer.decode(bytes).reason, NearbyDeclineReason.user);
    });

    test('rejects a wrong length, another version and an unknown kind', () {
      final good =
          NearbyAnswer(transferId: _id(1), kind: NearbyAnswerKind.accepted)
              .encode();
      expect(
        () => NearbyAnswer.decode(good.sublist(0, 18)),
        throwsFormatException,
      );
      expect(
        () => NearbyAnswer.decode(Uint8List.fromList([...good, 0])),
        throwsFormatException,
      );
      expect(
        () => NearbyAnswer.decode(Uint8List.fromList(good)..[0] = 2),
        throwsFormatException,
      );
      expect(
        () => NearbyAnswer.decode(Uint8List.fromList(good)..[17] = 0x09),
        throwsFormatException,
      );
    });
  });

  test('hex helpers round-trip', () {
    expect(nearbyUnhex(nearbyHex(_id(5))), _id(5));
    expect(() => nearbyUnhex('zz'), throwsFormatException);
  });

  group('answer v2 (Wi-Fi endpoint)', () {
    Uint8List key() => Uint8List.fromList(List.generate(32, (i) => i + 1));
    Uint8List tid() => Uint8List.fromList(List.generate(16, (i) => 200 - i));

    test('an answer without an endpoint is still nineteen bytes, version 1',
        () {
      final bytes = NearbyAnswer(
        transferId: tid(),
        kind: NearbyAnswerKind.accepted,
      ).encode();
      expect(bytes.length, NearbyAnswer.length);
      expect(bytes[0], nearbyVersion);
    });

    test('an endpoint round-trips', () {
      final a = NearbyAnswer(
        transferId: tid(),
        kind: NearbyAnswerKind.accepted,
        wifi: NearbyWifiEndpoint(
          address: '192.168.1.23',
          port: 40123,
          key: key(),
        ),
      );
      final bytes = a.encode();
      expect(bytes[0], nearbyAnswerVersionWifi);
      final back = NearbyAnswer.decode(bytes);
      expect(back.kind, NearbyAnswerKind.accepted);
      expect(back.wifi!.address, '192.168.1.23');
      expect(back.wifi!.port, 40123);
      expect(back.wifi!.key, key());
    });

    test('IPv6 round-trips', () {
      final back = NearbyAnswer.decode(
        NearbyAnswer(
          transferId: tid(),
          kind: NearbyAnswerKind.accepted,
          wifi: NearbyWifiEndpoint(address: 'fe80::1', port: 1, key: key()),
        ).encode(),
      );
      expect(back.wifi!.address, 'fe80::1');
    });

    test('only an acceptance may carry an endpoint', () {
      expect(
        () => NearbyAnswer(
          transferId: tid(),
          kind: NearbyAnswerKind.declined,
          wifi: NearbyWifiEndpoint(address: '10.0.0.2', port: 5, key: key()),
        ),
        throwsArgumentError,
      );
    });

    test('bad endpoints are refused on construction', () {
      expect(
        () => NearbyWifiEndpoint(address: 'not-an-ip', port: 5, key: key()),
        throwsArgumentError,
      );
      expect(
        () => NearbyWifiEndpoint(address: '10.0.0.2', port: 0, key: key()),
        throwsArgumentError,
      );
      expect(
        () => NearbyWifiEndpoint(
          address: '10.0.0.2',
          port: 5,
          key: Uint8List(31),
        ),
        throwsArgumentError,
      );
    });

    test('tampered v2 bytes throw FormatException', () {
      final good = NearbyAnswer(
        transferId: tid(),
        kind: NearbyAnswerKind.accepted,
        wifi: NearbyWifiEndpoint(address: '10.0.0.2', port: 5, key: key()),
      ).encode();
      // truncated
      expect(
        () => NearbyAnswer.decode(Uint8List.sublistView(good, 0, 30)),
        throwsFormatException,
      );
      // trailing byte
      expect(
        () => NearbyAnswer.decode(Uint8List.fromList([...good, 0])),
        throwsFormatException,
      );
      // address length pointing past the end
      final longAddr = Uint8List.fromList(good)..[19] = 200;
      expect(() => NearbyAnswer.decode(longAddr), throwsFormatException);
      // a v2 answer that is not an acceptance
      final notAccepted = Uint8List.fromList(good)
        ..[17] = NearbyAnswerKind.declined.tag;
      expect(() => NearbyAnswer.decode(notAccepted), throwsFormatException);
      // v1 with the wrong length is still refused
      final v1 = Uint8List.fromList(good)..[0] = nearbyVersion;
      expect(() => NearbyAnswer.decode(v1), throwsFormatException);
    });
  });

  group('NearbyBump', () {
    Uint8List card(int len, {int seed = 0}) =>
        Uint8List.fromList(List.generate(len, (i) => (seed + i) & 0xFF));

    // [0]=ver [1..16]=bumpId [17]=flags [18..19]=cardLen [20..]=card
    const cardLenAt = 1 + nearbyIdLen + 1;

    test('the tag byte is 0xEA and nothing else claims it', () {
      expect(InnerPayloadType.nearbyBump.tag, 0xEA);
      expect(InnerPayloadType.fromByte(0xEA), InnerPayloadType.nearbyBump);
      final sameTag = InnerPayloadType.values
          .where((v) => v.tag == 0xEA)
          .toList(growable: false);
      expect(sameTag, hasLength(1));
    });

    test('round-trips a 300-byte card, with and without files pending', () {
      for (final hasFiles in [true, false]) {
        final bump = NearbyBump(
          bumpId: _id(50),
          hasFiles: hasFiles,
          card: card(300, seed: 3),
        );
        final back = NearbyBump.decode(bump.encode());
        expect(back.bumpId, _id(50));
        expect(back.hasFiles, hasFiles);
        expect(back.card, card(300, seed: 3));
      }
    });

    test('refuses to encode a card past the 2048-byte limit', () {
      expect(
        () => NearbyBump(
          bumpId: _id(1),
          hasFiles: false,
          card: card(NearbyBump.maxCard + 1),
        ),
        throwsArgumentError,
      );
    });

    // Symmetric with decode refusing cardLen 0 below: an encoder that let this
    // through would build bytes its own decoder calls malformed.
    test('refuses to encode an empty card', () {
      expect(
        () => NearbyBump(
          bumpId: _id(1),
          hasFiles: false,
          card: card(0),
        ),
        throwsArgumentError,
      );
    });

    group('decode rejects', () {
      Uint8List good() => NearbyBump(
            bumpId: _id(4),
            hasFiles: true,
            card: card(20, seed: 1),
          ).encode();

      test('an unknown version', () {
        final bad = Uint8List.fromList(good())..[0] = 0x02;
        expect(() => NearbyBump.decode(bad), throwsFormatException);
      });

      test('a truncated body', () {
        final bytes = good();
        expect(
          () => NearbyBump.decode(bytes.sublist(0, bytes.length - 1)),
          throwsFormatException,
        );
      });

      test('a trailing byte', () {
        expect(
          () => NearbyBump.decode(Uint8List.fromList([...good(), 0])),
          throwsFormatException,
        );
      });

      test('a cardLen running past the end', () {
        final bad = Uint8List.fromList(good())
          ..[cardLenAt] = 0xFF
          ..[cardLenAt + 1] = 0xFF;
        expect(() => NearbyBump.decode(bad), throwsFormatException);
      });

      test('an empty card', () {
        final withOneByteCard =
            NearbyBump(bumpId: _id(4), hasFiles: false, card: card(1)).encode();
        final bad = Uint8List.fromList(
          withOneByteCard.sublist(0, withOneByteCard.length - 1),
        )
          ..[cardLenAt] = 0
          ..[cardLenAt + 1] = 0;
        expect(() => NearbyBump.decode(bad), throwsFormatException);
      });
    });
  });
}
