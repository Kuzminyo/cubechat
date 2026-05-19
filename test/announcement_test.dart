import 'dart:typed_data';

import 'package:cubechat/core/transport/announcement.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PeerAnnouncement', () {
    test('roundtrip preserves pubkey and nickname', () {
      final pub = Uint8List.fromList(List.generate(32, (i) => i + 1));
      final ann = PeerAnnouncement(pubkey: pub, nickname: 'Alice');
      final wire = ann.encode();
      final decoded = PeerAnnouncement.decode(wire);
      expect(decoded.pubkey, equals(pub));
      expect(decoded.nickname, 'Alice');
    });

    test('UTF-8 nickname survives the round-trip', () {
      final pub = Uint8List(32);
      final ann = PeerAnnouncement(pubkey: pub, nickname: 'Алиса 🦊');
      final decoded = PeerAnnouncement.decode(ann.encode());
      expect(decoded.nickname, 'Алиса 🦊');
    });

    test('empty nickname is legal', () {
      final pub = Uint8List(32);
      final ann = PeerAnnouncement(pubkey: pub, nickname: '');
      final decoded = PeerAnnouncement.decode(ann.encode());
      expect(decoded.nickname, '');
    });

    test('wrong-length pubkey throws on construction', () {
      expect(
        () => PeerAnnouncement(pubkey: Uint8List(31), nickname: 'x'),
        throwsA(isA<AssertionError>()),
      );
    });

    test('truncated wire bytes throw FormatException', () {
      // Just version + part of pubkey (no length byte at all).
      expect(
        () => PeerAnnouncement.decode(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<FormatException>()),
      );
    });

    test('unknown version byte throws', () {
      // Version 0x02 (unknown) + 32B + 0-byte name.
      final bad = Uint8List(1 + 32 + 1)..[0] = 0x02;
      expect(
        () => PeerAnnouncement.decode(bad),
        throwsA(isA<FormatException>()),
      );
    });

    test('nameLen longer than remaining bytes throws', () {
      final bad = Uint8List(1 + 32 + 1);
      bad[0] = 1;
      bad[33] = 99; // claims 99 bytes of name, but there are 0
      expect(
        () => PeerAnnouncement.decode(bad),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
