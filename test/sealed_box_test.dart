import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/crypto/sealed_box.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SealedBox', () {
    late SimpleKeyPairData recipient;
    late Uint8List recipientPub;

    setUp(() async {
      final kp = await X25519().newKeyPair();
      final pub = await kp.extractPublicKey();
      final priv = await kp.extractPrivateKeyBytes();
      recipient = SimpleKeyPairData(
        priv,
        publicKey: pub,
        type: KeyPairType.x25519,
      );
      recipientPub = Uint8List.fromList(pub.bytes);
    });

    test('seal then open recovers the plaintext', () async {
      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      final wire = await SealedBox.seal(plaintext, recipientPub);

      // ephemeral pub (32) + ct (N) + tag (16) = N + 48
      expect(wire.length, plaintext.length + SealedBox.overhead);

      final recovered = await SealedBox.open(
        wire,
        recipientKeyPair: recipient,
        recipientPubkey: recipientPub,
      );
      expect(recovered, equals(plaintext));
    });

    test('UTF-8 message survives the round-trip', () async {
      final msg = Uint8List.fromList('Привет 🦊 cubechat'.codeUnits);
      final wire = await SealedBox.seal(msg, recipientPub);
      final recovered = await SealedBox.open(
        wire,
        recipientKeyPair: recipient,
        recipientPubkey: recipientPub,
      );
      expect(recovered, equals(msg));
    });

    test('two seals of the same plaintext produce different ciphertexts',
        () async {
      final pt = Uint8List.fromList([42, 42, 42, 42]);
      final a = await SealedBox.seal(pt, recipientPub);
      final b = await SealedBox.seal(pt, recipientPub);
      // Different ephemeral keys → different ciphertexts. Both must still
      // open to the same plaintext.
      expect(a, isNot(equals(b)));
      final ra = await SealedBox.open(a,
          recipientKeyPair: recipient, recipientPubkey: recipientPub);
      final rb = await SealedBox.open(b,
          recipientKeyPair: recipient, recipientPubkey: recipientPub);
      expect(ra, equals(pt));
      expect(rb, equals(pt));
    });

    test('wrong recipient key fails to open', () async {
      final pt = Uint8List.fromList([1, 2, 3]);
      final wire = await SealedBox.seal(pt, recipientPub);

      final stranger = await X25519().newKeyPair();
      final strangerPub = await stranger.extractPublicKey();
      final strangerPriv = await stranger.extractPrivateKeyBytes();
      final strangerKeyPair = SimpleKeyPairData(
        strangerPriv,
        publicKey: strangerPub,
        type: KeyPairType.x25519,
      );
      final strangerPubBytes = Uint8List.fromList(strangerPub.bytes);

      // Open with a key pair that doesn't match the seal target → AEAD fails.
      await expectLater(
        () => SealedBox.open(wire,
            recipientKeyPair: strangerKeyPair,
            recipientPubkey: strangerPubBytes),
        throwsA(anyOf(
          isA<SecretBoxAuthenticationError>(),
          isA<Exception>(),
        )),
      );
    });

    test('truncated wire bytes throw FormatException', () async {
      final shortBytes =
          Uint8List(SealedBox.ephemeralPubLen + SealedBox.tagLen - 1);
      await expectLater(
        () => SealedBox.open(shortBytes,
            recipientKeyPair: recipient, recipientPubkey: recipientPub),
        throwsA(isA<FormatException>()),
      );
    });

    test('flipped ciphertext byte fails the authentication tag', () async {
      final pt = Uint8List.fromList([10, 20, 30, 40]);
      final wire = await SealedBox.seal(pt, recipientPub);
      // Flip a byte inside the ciphertext region (between ephemeral and tag).
      final tampered = Uint8List.fromList(wire);
      tampered[SealedBox.ephemeralPubLen] ^= 0x80;
      await expectLater(
        () => SealedBox.open(tampered,
            recipientKeyPair: recipient, recipientPubkey: recipientPub),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });
}
