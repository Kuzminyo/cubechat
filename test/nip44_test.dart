import 'dart:convert';
import 'dart:typed_data';

import 'package:cubechat/core/nostr/nip44.dart';
import 'package:cubechat/core/nostr/secp256k1.dart';
import 'package:flutter_test/flutter_test.dart';

/// Official NIP-44 v2 vectors, copied verbatim from
/// github.com/paulmillr/nip44 (nip44.vectors.json). A self-consistent but
/// subtly-wrong implementation passes a roundtrip test; only known-answer
/// vectors catch a wrong ChaCha counter, HKDF order, or ECDH lift.
void main() {
  Uint8List hx(String s) {
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  group('calc_padded_len (official vectors)', () {
    const cases = [
      [16, 32], [32, 32], [33, 64], [37, 64], [45, 64], [49, 64], [64, 64],
      [65, 96], [100, 128], [111, 128], [200, 224], [250, 256], [320, 320],
      [383, 384], [384, 384], [400, 448], [500, 512], [512, 512], [515, 640],
      [700, 768], [800, 896], [900, 1024], [1020, 1024], [65536, 65536],
    ];
    for (final c in cases) {
      test('${c[0]} -> ${c[1]}', () {
        expect(Nip44.calcPaddedLen(c[0]), c[1]);
      });
    }
  });

  group('conversation key (ECDH, official vectors)', () {
    test('vector 1', () {
      final ck = Nip44.conversationKey(
        '315e59ff51cb9209768cf7da80791ddcaae56ac9775eb25b6dee1234bc5d2268',
        'c2f9d9948dc8c7c38321e4b85c8558872eafa0641cd269db76848a6073e69133',
      );
      expect(ck,
          equals(hx('3dfef0ce2a4d80a25e7a328accf73448ef67096f65f79588e358d9a0eb9013f1')));
    });

    test('vector 2', () {
      final ck = Nip44.conversationKey(
        'a1e37752c9fdc1273be53f68c5f74be7c8905728e8de75800b94262f9497c86e',
        '03bb7947065dde12ba991ea045132581d0954f042c84e06d8c00066e23c1a800',
      );
      expect(ck,
          equals(hx('4d14f36e81b8452128da64fe6f1eae873baae2f444b02c950b90e43553f2178b')));
    });

    test('ECDH is commutative (a→B == b→A) via derived pubkeys', () {
      const secA =
          '0000000000000000000000000000000000000000000000000000000000000001';
      const secB =
          '0000000000000000000000000000000000000000000000000000000000000002';
      final pubA = Secp256k1.publicKeyHex(secA);
      final pubB = Secp256k1.publicKeyHex(secB);
      final ab = Nip44.conversationKey(secA, pubB);
      final ba = Nip44.conversationKey(secB, pubA);
      expect(ab, equals(ba));
      // And it matches the vector's shared conversation key.
      expect(ab,
          equals(hx('c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d')));
    });
  });

  group('encrypt/decrypt (official vectors)', () {
    final ck = hx(
        'c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d');

    test('vector 1 — plaintext "a"', () {
      const nonce =
          '0000000000000000000000000000000000000000000000000000000000000001';
      const payload =
          'AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb';
      final got = Nip44.encryptWithNonce('a', ck, hx(nonce));
      expect(base64.normalize(got), base64.normalize(payload));
      expect(Nip44.decrypt(payload, ck), 'a');
    });

    test('vector 2 — plaintext "🍕🫃"', () {
      const nonce =
          'f00000000000000000000000000000f00000000000000000000000000000000f';
      const payload =
          'AvAAAAAAAAAAAAAAAAAAAPAAAAAAAAAAAAAAAAAAAAAPSKSK6is9ngkX2+cSq85Th16oRTISAOfhStnixqZziKMDvB0QQzgFZdjLTPicCJaV8nDITO+QfaQ61+KbWQIOO2Yj';
      final got = Nip44.encryptWithNonce('🍕🫃', ck, hx(nonce));
      expect(base64.normalize(got), base64.normalize(payload));
      expect(Nip44.decrypt(payload, ck), '🍕🫃');
    });
  });

  group('roundtrip + tamper', () {
    test('random-nonce roundtrip preserves the message', () {
      final ck = Nip44.conversationKey(
        '0000000000000000000000000000000000000000000000000000000000000003',
        Secp256k1.publicKeyHex(
            '0000000000000000000000000000000000000000000000000000000000000004'),
      );
      const msg = 'Захищене повідомлення через Nostr 🔐';
      expect(Nip44.decrypt(Nip44.encrypt(msg, ck), ck), msg);
    });

    test('a flipped ciphertext byte fails the MAC', () {
      final ck = Nip44.conversationKey(
        '0000000000000000000000000000000000000000000000000000000000000003',
        Secp256k1.publicKeyHex(
            '0000000000000000000000000000000000000000000000000000000000000004'),
      );
      final payload = Nip44.encrypt('tamper me', ck);
      final bytes = base64.decode(base64.normalize(payload));
      bytes[40] ^= 0xff; // somewhere in the ciphertext region
      expect(() => Nip44.decrypt(base64.encode(bytes), ck),
          throwsA(isA<FormatException>()));
    });
  });
}
