import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/transport/announcement.dart';
import 'package:cubechat/core/transport/contact_card.dart';
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

/// A signed card for a throwaway identity, plus the bytes behind it.
Future<({String card, Uint8List wire, Uint8List npub})> _card({
  String nickname = 'Alice',
}) async {
  final ed = await _newEd();
  final ann = PeerAnnouncement(
    pubkey: _key(1),
    signPubkey: ed.pub,
    signedPrekeyPub: _key(70),
    nostrPubkey: _key(130),
    nickname: nickname,
  );
  final wire = await ann.sign(ed.kp);
  return (card: ContactCard.encode(wire), wire: wire, npub: _key(130));
}

void main() {
  group('ContactCard', () {
    test('encode + parse roundtrips the whole identity bundle', () async {
      final ed = await _newEd();
      final ann = PeerAnnouncement(
        pubkey: _key(1),
        signPubkey: ed.pub,
        signedPrekeyPub: _key(70),
        nostrPubkey: _key(130),
        nickname: 'Alice',
      );
      final card = ContactCard.encode(await ann.sign(ed.kp));

      final decoded = await ContactCard.parse(card);
      expect(decoded.pubkey, equals(_key(1)));
      expect(decoded.signPubkey, equals(ed.pub));
      expect(decoded.signedPrekeyPub, equals(_key(70)));
      expect(
        decoded.nostrPubkey,
        equals(_key(130)),
        reason: 'the npub is what makes an off-mesh first contact possible',
      );
      expect(decoded.nickname, 'Alice');
    });

    test('carries the scheme prefix', () async {
      final c = await _card();
      expect(c.card, startsWith(ContactCard.scheme));
    });

    test('UTF-8 nickname survives the round trip', () async {
      final c = await _card(nickname: 'Аліса 🦊');
      expect((await ContactCard.parse(c.card)).nickname, 'Аліса 🦊');
    });

    // --- tolerant input handling ------------------------------------------

    test('parses when embedded in surrounding chat text', () async {
      final c = await _card();
      final pasted = 'hey, add me:\n${c.card}\nsee you';
      expect((await ContactCard.parse(pasted)).nickname, 'Alice');
    });

    test('parses across line breaks injected by a mail client', () async {
      final c = await _card();
      final mid = c.card.length ~/ 2;
      final wrapped = '${c.card.substring(0, mid)}\r\n${c.card.substring(mid)}';
      expect((await ContactCard.parse(wrapped)).nickname, 'Alice');
    });

    test('accepts the :// spelling some apps linkify instead', () async {
      final c = await _card();
      final token = c.card.substring(ContactCard.scheme.length);
      expect(
        (await ContactCard.parse('${ContactCard.uriScheme}$token')).nickname,
        'Alice',
      );
    });

    test('accepts a bare token whose scheme was stripped in transit', () async {
      final c = await _card();
      final token = c.card.substring(ContactCard.scheme.length);
      expect((await ContactCard.parse(token)).nickname, 'Alice');
    });

    test('looksLikeCard gates on shape, not on signature', () async {
      final c = await _card();
      expect(ContactCard.looksLikeCard(c.card), isTrue);
      expect(ContactCard.looksLikeCard('  '), isFalse);
      expect(ContactCard.looksLikeCard('just a sentence'), isFalse);
      // Too short to be an announcement, so a bare word is not mistaken for one.
      expect(ContactCard.looksLikeCard('abcdef'), isFalse);
    });

    // --- rejection --------------------------------------------------------

    test('empty / non-card text throws', () async {
      await expectLater(
        () => ContactCard.parse(''),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        () => ContactCard.parse('hello there'),
        throwsA(isA<FormatException>()),
      );
    });

    test('scheme with a truncated payload throws', () async {
      await expectLater(
        () => ContactCard.parse('${ContactCard.scheme}AAAA'),
        throwsA(isA<FormatException>()),
      );
    });

    test('a card whose bytes were edited in transit is rejected', () async {
      final ed = await _newEd();
      final ann = PeerAnnouncement(
        pubkey: _key(1),
        signPubkey: ed.pub,
        signedPrekeyPub: _key(70),
        nostrPubkey: _key(130),
        nickname: 'Alice',
      );
      final wire = await ann.sign(ed.kp);
      // Swap in an attacker's Nostr address — the whole point of the signature
      // is that this cannot be done without the holder's Ed25519 key.
      wire[1 + 32 + 32 + 32] ^= 0x11;

      await expectLater(
        () => ContactCard.parse(ContactCard.encode(wire)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a card signed by someone else for these keys is rejected', () async {
      final real = await _newEd();
      final imposter = await _newEd();
      final ann = PeerAnnouncement(
        pubkey: _key(1),
        signPubkey: real.pub,
        signedPrekeyPub: _key(70),
        nostrPubkey: _key(130),
        nickname: 'Alice',
      );
      final wire = await ann.sign(imposter.kp);
      await expectLater(
        () => ContactCard.parse(ContactCard.encode(wire)),
        throwsA(isA<FormatException>()),
      );
    });

    test('tryDecodeBytes returns the exact announcement bytes', () async {
      final c = await _card();
      expect(ContactCard.tryDecodeBytes(c.card), equals(c.wire));
      expect(ContactCard.tryDecodeBytes('nope'), isNull);
    });

    test('stays short enough to be a scannable QR code', () async {
      final c = await _card(nickname: 'Alice');
      // ~194 announcement bytes -> ~259 base64 chars + prefix. Well inside the
      // byte-mode capacity of a mid-size QR at error-correction level M.
      expect(c.card.length, lessThan(400));
    });
  });
}
