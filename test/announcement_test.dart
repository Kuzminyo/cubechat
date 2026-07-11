import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/transport/announcement.dart';
import 'package:flutter_test/flutter_test.dart';

Future<({SimpleKeyPairData kp, Uint8List pub})> _newEd() async {
  final pair = await Ed25519().newKeyPair();
  final pub = await pair.extractPublicKey();
  final seed = await pair.extractPrivateKeyBytes();
  return (
    kp: SimpleKeyPairData(seed, publicKey: pub, type: KeyPairType.ed25519),
    pub: Uint8List.fromList(pub.bytes),
  );
}

Uint8List _key(int base) =>
    Uint8List.fromList(List.generate(32, (i) => (base + i) & 0xFF));

void main() {
  group('PeerAnnouncement', () {
    test('sign + verifyAndDecode roundtrips every field', () async {
      final ed = await _newEd();
      final x25519 = _key(1);
      final spk = _key(70);
      final npub = _key(130);
      final ann = PeerAnnouncement(
        pubkey: x25519,
        signPubkey: ed.pub,
        signedPrekeyPub: spk,
        nostrPubkey: npub,
        nickname: 'Alice',
      );
      final wire = await ann.sign(ed.kp);
      final decoded = await PeerAnnouncement.verifyAndDecode(wire);
      expect(decoded.pubkey, equals(x25519));
      expect(decoded.signPubkey, equals(ed.pub));
      expect(decoded.signedPrekeyPub, equals(spk));
      expect(decoded.nostrPubkey, equals(npub));
      expect(decoded.nickname, 'Alice');
    });

    test('UTF-8 nickname survives signing', () async {
      final ed = await _newEd();
      final ann = PeerAnnouncement(
        pubkey: Uint8List(32),
        signPubkey: ed.pub,
        signedPrekeyPub: Uint8List(32),
        nostrPubkey: Uint8List(32),
        nickname: 'Алиса 🦊',
      );
      final decoded = await PeerAnnouncement.verifyAndDecode(
        await ann.sign(ed.kp),
      );
      expect(decoded.nickname, 'Алиса 🦊');
    });

    test('empty nickname is legal', () async {
      final ed = await _newEd();
      final ann = PeerAnnouncement(
        pubkey: Uint8List(32),
        signPubkey: ed.pub,
        signedPrekeyPub: Uint8List(32),
        nostrPubkey: Uint8List(32),
        nickname: '',
      );
      final decoded = await PeerAnnouncement.verifyAndDecode(
        await ann.sign(ed.kp),
      );
      expect(decoded.nickname, '');
    });

    test('wrong-length pubkey throws on construction', () async {
      final ed = await _newEd();
      expect(
        () => PeerAnnouncement(
          pubkey: Uint8List(31),
          signPubkey: ed.pub,
          signedPrekeyPub: Uint8List(32),
          nostrPubkey: Uint8List(32),
          nickname: 'x',
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('wrong-length nostrPubkey throws on construction', () async {
      final ed = await _newEd();
      expect(
        () => PeerAnnouncement(
          pubkey: Uint8List(32),
          signPubkey: ed.pub,
          signedPrekeyPub: Uint8List(32),
          nostrPubkey: Uint8List(31),
          nickname: 'x',
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('truncated wire bytes throw FormatException', () async {
      await expectLater(
        () => PeerAnnouncement.verifyAndDecode(
          Uint8List.fromList([1, 2, 3]),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('unknown version byte throws', () async {
      final bad = Uint8List(1 + 32 * 4 + 1 + 64)..[0] = 0x99;
      await expectLater(
        () => PeerAnnouncement.verifyAndDecode(bad),
        throwsA(isA<FormatException>()),
      );
    });

    test('tampered signature fails verification', () async {
      final ed = await _newEd();
      final ann = PeerAnnouncement(
        pubkey: Uint8List(32),
        signPubkey: ed.pub,
        signedPrekeyPub: Uint8List(32),
        nostrPubkey: Uint8List(32),
        nickname: 'x',
      );
      final wire = await ann.sign(ed.kp);
      wire[wire.length - 1] ^= 0x40;
      await expectLater(
        () => PeerAnnouncement.verifyAndDecode(wire),
        throwsA(isA<FormatException>()),
      );
    });

    test('tampered nostrPubkey fails verification', () async {
      final ed = await _newEd();
      final ann = PeerAnnouncement(
        pubkey: Uint8List(32),
        signPubkey: ed.pub,
        signedPrekeyPub: Uint8List(32),
        nostrPubkey: _key(130),
        nickname: 'Alice',
      );
      final wire = await ann.sign(ed.kp);
      // Flip a byte inside the npub region (after version + x25519 + ed + spk).
      wire[1 + 32 + 32 + 32] ^= 0x11;
      await expectLater(
        () => PeerAnnouncement.verifyAndDecode(wire),
        throwsA(isA<FormatException>()),
      );
    });

    test('tampered nickname fails verification', () async {
      final ed = await _newEd();
      final ann = PeerAnnouncement(
        pubkey: Uint8List(32),
        signPubkey: ed.pub,
        signedPrekeyPub: Uint8List(32),
        nostrPubkey: Uint8List(32),
        nickname: 'Alice',
      );
      final wire = await ann.sign(ed.kp);
      // Mutate one byte of the name region (between header and signature).
      wire[1 + 32 * 4 + 1] ^= 0x20;
      await expectLater(
        () => PeerAnnouncement.verifyAndDecode(wire),
        throwsA(isA<FormatException>()),
      );
    });

    test('forged signPubkey fails verification', () async {
      final real = await _newEd();
      final imposter = await _newEd();
      final ann = PeerAnnouncement(
        pubkey: Uint8List(32),
        signPubkey: real.pub,
        signedPrekeyPub: Uint8List(32),
        nostrPubkey: Uint8List(32),
        nickname: 'Alice',
      );
      // Sign with the impostor's keys but claim to be 'real'.
      final wire = await ann.sign(imposter.kp);
      await expectLater(
        () => PeerAnnouncement.verifyAndDecode(wire),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
