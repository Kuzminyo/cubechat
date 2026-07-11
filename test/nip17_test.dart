import 'dart:convert';

import 'package:cubechat/core/nostr/nip17.dart';
import 'package:cubechat/core/nostr/nip44.dart';
import 'package:cubechat/core/nostr/nostr_event.dart';
import 'package:cubechat/core/nostr/secp256k1.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Two fixed identities.
  const alicePriv =
      '0000000000000000000000000000000000000000000000000000000000000001';
  const bobPriv =
      '0000000000000000000000000000000000000000000000000000000000000002';
  final alicePub = Secp256k1.publicKeyHex(alicePriv);
  final bobPub = Secp256k1.publicKeyHex(bobPriv);

  group('NIP-17 gift wrap', () {
    test('wrap → unwrap round-trips and attributes the sender', () {
      final wrap = Nip17.wrap(
        senderPrivHex: alicePriv,
        recipientPubHex: bobPub,
        content: 'привіт через Nostr 🔐',
      );
      expect(wrap.kind, Nip17.kindGiftWrap);
      expect(wrap.verify(), isTrue);

      final open = Nip17.unwrap(recipientPrivHex: bobPriv, giftWrap: wrap);
      expect(open.content, 'привіт через Nostr 🔐');
      expect(open.senderPubHex, alicePub);
    });

    test('gift wrap hides the real sender (ephemeral pubkey, p-tag only)', () {
      final wrap = Nip17.wrap(
        senderPrivHex: alicePriv,
        recipientPubHex: bobPub,
        content: 'hidden',
      );
      // The outer event is signed by a throwaway key, not Alice.
      expect(wrap.pubkey, isNot(alicePub));
      // Only the recipient is referenced on the outside.
      expect(wrap.tags, [
        ['p', bobPub],
      ]);
      // Nothing about Alice is in the cleartext.
      expect(wrap.content.contains(alicePub), isFalse);
    });

    test('a third party cannot open it', () {
      const evePriv =
          '0000000000000000000000000000000000000000000000000000000000000009';
      final wrap = Nip17.wrap(
        senderPrivHex: alicePriv,
        recipientPubHex: bobPub,
        content: 'secret',
      );
      expect(
        () => Nip17.unwrap(recipientPrivHex: evePriv, giftWrap: wrap),
        throwsA(isA<FormatException>()),
      );
    });

    test('a forged rumor author (seal ≠ rumor pubkey) is rejected', () {
      // Alice seals a rumor that lies about being from Bob. Unwrapping must
      // refuse rather than mis-attribute the message.
      final base = DateTime.now();
      final forgedRumor = NostrEvent.rumor(
        pubkey: bobPub, // lie: claims Bob wrote it
        createdAt: base.millisecondsSinceEpoch ~/ 1000,
        kind: Nip17.kindRumor,
        tags: [
          ['p', bobPub],
        ],
        content: 'I am definitely Bob',
      );
      final sealKey = Nip44.conversationKey(alicePriv, bobPub);
      final seal = NostrEvent.signed(
        privHex: alicePriv, // but sealed + signed by Alice
        createdAt: base.millisecondsSinceEpoch ~/ 1000,
        kind: Nip17.kindSeal,
        tags: const [],
        content: Nip44.encrypt(forgedRumor.encode(), sealKey),
      );
      final ephemeralPriv =
          '00000000000000000000000000000000000000000000000000000000000000aa';
      final wrapKey = Nip44.conversationKey(ephemeralPriv, bobPub);
      final wrap = NostrEvent.signed(
        privHex: ephemeralPriv,
        createdAt: base.millisecondsSinceEpoch ~/ 1000,
        kind: Nip17.kindGiftWrap,
        tags: [
          ['p', bobPub],
        ],
        content: Nip44.encrypt(seal.encode(), wrapKey),
      );

      expect(
        () => Nip17.unwrap(recipientPrivHex: bobPriv, giftWrap: wrap),
        throwsA(isA<FormatException>()),
      );
    });

    test('event id + signature verify against a hand-built event', () {
      final ev = NostrEvent.signed(
        privHex: alicePriv,
        createdAt: 1700000000,
        kind: 1,
        tags: const [],
        content: 'gm',
      );
      expect(ev.pubkey, alicePub);
      expect(ev.verify(), isTrue);
      // Tampering with content breaks the id/signature link.
      final tampered = NostrEvent.fromJson(
        (jsonDecode(ev.encode()) as Map<String, dynamic>)..['content'] = 'gn',
      );
      expect(tampered.verify(), isFalse);
    });
  });
}
