import 'dart:typed_data';

import 'package:cubechat/core/crypto/secp256k1.dart';
import 'package:cubechat/core/transport/nostr/nostr_event.dart';
import 'package:cubechat/core/transport/nostr/nostr_signer.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _seed(int fill) => Uint8List.fromList(List.filled(32, fill));

Uint8List _unhex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

NostrEvent _event(String npub) => NostrEvent(
      pubkey: npub,
      createdAt: 1700000000,
      kind: 1059,
      tags: [
        ['p', 'bb' * 32],
      ],
      content: 'cc1:SGVsbG8=',
    );

void main() {
  group('Secp256k1NostrSigner derivation', () {
    test('is deterministic — same seed yields the same npub', () async {
      final a = await Secp256k1NostrSigner.deriveFromSeed(_seed(7));
      final b = await Secp256k1NostrSigner.deriveFromSeed(_seed(7));
      expect(a.npubHex, b.npubHex);
    });

    test('npub is a 64-char lowercase-hex x-only key', () async {
      final s = await Secp256k1NostrSigner.deriveFromSeed(_seed(1));
      expect(s.npubHex.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(s.npubHex), isTrue);
    });

    test('different seeds yield different npubs', () async {
      final a = await Secp256k1NostrSigner.deriveFromSeed(_seed(1));
      final b = await Secp256k1NostrSigner.deriveFromSeed(_seed(2));
      expect(a.npubHex, isNot(b.npubHex));
    });
  });

  group('Secp256k1NostrSigner signing', () {
    test('stamps a valid event id and a BIP-340 signature that verifies',
        () async {
      final signer = await Secp256k1NostrSigner.deriveFromSeed(_seed(9));
      final signed = await signer.sign(_event(signer.npubHex));

      // Event id is populated and self-consistent.
      expect(await signed.hasValidId(), isTrue);
      expect(signed.sig, isNotNull);
      expect(signed.sig!.length, 128); // 64-byte schnorr sig in hex

      // The Schnorr signature verifies against the signer's npub over the id.
      final ok = await Secp256k1.verify(
        publicKey: _unhex(signer.npubHex),
        message: _unhex(signed.id!),
        signature: _unhex(signed.sig!),
      );
      expect(ok, isTrue);
    });

    test('signature does not verify against a different pubkey', () async {
      final signer = await Secp256k1NostrSigner.deriveFromSeed(_seed(9));
      final other = await Secp256k1NostrSigner.deriveFromSeed(_seed(10));
      final signed = await signer.sign(_event(signer.npubHex));

      final ok = await Secp256k1.verify(
        publicKey: _unhex(other.npubHex),
        message: _unhex(signed.id!),
        signature: _unhex(signed.sig!),
      );
      expect(ok, isFalse);
    });

    test('two signatures over the same event both verify (fresh aux nonce)',
        () async {
      final signer = await Secp256k1NostrSigner.deriveFromSeed(_seed(3));
      final a = await signer.sign(_event(signer.npubHex));
      final b = await signer.sign(_event(signer.npubHex));
      for (final signed in [a, b]) {
        expect(
          await Secp256k1.verify(
            publicKey: _unhex(signer.npubHex),
            message: _unhex(signed.id!),
            signature: _unhex(signed.sig!),
          ),
          isTrue,
        );
      }
    });
  });
}
