import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/crypto/fs_message.dart';
import 'package:cubechat/core/crypto/x3dh.dart';
import 'package:flutter_test/flutter_test.dart';

Future<SimpleKeyPairData> _x25519() async {
  final kp = await X25519().newKeyPair();
  final pub = await kp.extractPublicKey();
  final priv = await kp.extractPrivateKeyBytes();
  return SimpleKeyPairData(priv, publicKey: pub, type: KeyPairType.x25519);
}

Uint8List _pub(SimpleKeyPairData kp) => Uint8List.fromList(kp.publicKey.bytes);

void main() {
  group('FsMessage + X3DH end-to-end', () {
    test('sender seals, receiver derives the key and opens', () async {
      // Alice (sender) and Bob (recipient).
      final aliceIK = await _x25519();
      final aliceEK = await _x25519();
      final bobIK = await _x25519();
      final bobSPK = await _x25519();

      final plaintext =
          Uint8List.fromList(List.generate(40, (i) => (i * 7) & 0xff));

      // --- sender side ---
      final senderKey = await X3dh.deriveSender(
        identityKeyPair: aliceIK,
        ephemeralKeyPair: aliceEK,
        recipientIdentityPub: _pub(bobIK),
        recipientSignedPrekeyPub: _pub(bobSPK),
      );
      final body = await FsMessage.seal(
        key: senderKey,
        plaintext: plaintext,
        senderIdentityPub: _pub(aliceIK),
        senderEphemeralPub: _pub(aliceEK),
      );

      // --- receiver side ---
      final parsed = FsMessage.parse(body);
      expect(parsed.senderIdentityPub, equals(_pub(aliceIK)));
      expect(parsed.senderEphemeralPub, equals(_pub(aliceEK)));
      final receiverKey = await X3dh.deriveReceiver(
        identityKeyPair: bobIK,
        signedPrekeyPair: bobSPK,
        senderIdentityPub: parsed.senderIdentityPub,
        senderEphemeralPub: parsed.senderEphemeralPub,
      );
      final recovered =
          await FsMessage.open(key: receiverKey, parsed: parsed);
      expect(recovered, equals(plaintext));
    });

    test('two messages reuse no nonce / ciphertext (fresh ephemeral)',
        () async {
      final aliceIK = await _x25519();
      final bobIK = await _x25519();
      final bobSPK = await _x25519();
      final pt = Uint8List.fromList([1, 2, 3, 4]);

      Future<Uint8List> once() async {
        final ek = await _x25519();
        final k = await X3dh.deriveSender(
          identityKeyPair: aliceIK,
          ephemeralKeyPair: ek,
          recipientIdentityPub: _pub(bobIK),
          recipientSignedPrekeyPub: _pub(bobSPK),
        );
        return FsMessage.seal(
          key: k,
          plaintext: pt,
          senderIdentityPub: _pub(aliceIK),
          senderEphemeralPub: _pub(ek),
        );
      }

      final a = await once();
      final b = await once();
      expect(a, isNot(equals(b)));
    });

    test('wrong recipient key fails the AEAD tag', () async {
      final aliceIK = await _x25519();
      final aliceEK = await _x25519();
      final bobIK = await _x25519();
      final bobSPK = await _x25519();
      final malloryIK = await _x25519();

      final senderKey = await X3dh.deriveSender(
        identityKeyPair: aliceIK,
        ephemeralKeyPair: aliceEK,
        recipientIdentityPub: _pub(bobIK),
        recipientSignedPrekeyPub: _pub(bobSPK),
      );
      final body = await FsMessage.seal(
        key: senderKey,
        plaintext: Uint8List.fromList([9, 9, 9]),
        senderIdentityPub: _pub(aliceIK),
        senderEphemeralPub: _pub(aliceEK),
      );
      final parsed = FsMessage.parse(body);
      // Wrong identity key → wrong derived key → tag check fails.
      final wrongKey = await X3dh.deriveReceiver(
        identityKeyPair: malloryIK,
        signedPrekeyPair: bobSPK,
        senderIdentityPub: parsed.senderIdentityPub,
        senderEphemeralPub: parsed.senderEphemeralPub,
      );
      await expectLater(
        () => FsMessage.open(key: wrongKey, parsed: parsed),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('truncated body throws FormatException', () {
      expect(
        () => FsMessage.parse(Uint8List(10)),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
