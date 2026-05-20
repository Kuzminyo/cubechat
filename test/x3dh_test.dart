import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/crypto/prekey_store.dart';
import 'package:cubechat/core/crypto/x3dh.dart';
import 'package:flutter_test/flutter_test.dart';

Future<SimpleKeyPairData> _x25519() async {
  final kp = await X25519().newKeyPair();
  final pub = await kp.extractPublicKey();
  final priv = await kp.extractPrivateKeyBytes();
  return SimpleKeyPairData(priv, publicKey: pub, type: KeyPairType.x25519);
}

Future<({SimpleKeyPairData kp, Uint8List pub})> _ed25519() async {
  final kp = await Ed25519().newKeyPair();
  final pub = await kp.extractPublicKey();
  final seed = await kp.extractPrivateKeyBytes();
  return (
    kp: SimpleKeyPairData(seed, publicKey: pub, type: KeyPairType.ed25519),
    pub: Uint8List.fromList(pub.bytes),
  );
}

Uint8List _pubOf(SimpleKeyPairData kp) =>
    Uint8List.fromList((kp.publicKey).bytes);

void main() {
  group('X3DH key agreement', () {
    test('sender and receiver derive the same key (with OPK)', () async {
      final ikA = await _x25519();
      final ekA = await _x25519();
      final ikB = await _x25519();
      final spkB = await _x25519();
      final opkB = await _x25519();

      final sk = await X3dh.deriveSender(
        identityKeyPair: ikA,
        ephemeralKeyPair: ekA,
        recipientIdentityPub: _pubOf(ikB),
        recipientSignedPrekeyPub: _pubOf(spkB),
        recipientOneTimePub: _pubOf(opkB),
      );
      final rk = await X3dh.deriveReceiver(
        identityKeyPair: ikB,
        signedPrekeyPair: spkB,
        oneTimeKeyPair: opkB,
        senderIdentityPub: _pubOf(ikA),
        senderEphemeralPub: _pubOf(ekA),
      );

      expect(await sk.extractBytes(), equals(await rk.extractBytes()));
    });

    test('sender and receiver agree without an OPK (fallback path)', () async {
      final ikA = await _x25519();
      final ekA = await _x25519();
      final ikB = await _x25519();
      final spkB = await _x25519();

      final sk = await X3dh.deriveSender(
        identityKeyPair: ikA,
        ephemeralKeyPair: ekA,
        recipientIdentityPub: _pubOf(ikB),
        recipientSignedPrekeyPub: _pubOf(spkB),
        recipientOneTimePub: null,
      );
      final rk = await X3dh.deriveReceiver(
        identityKeyPair: ikB,
        signedPrekeyPair: spkB,
        oneTimeKeyPair: null,
        senderIdentityPub: _pubOf(ikA),
        senderEphemeralPub: _pubOf(ekA),
      );
      expect(await sk.extractBytes(), equals(await rk.extractBytes()));
    });

    test('with-OPK and without-OPK keys differ for the same parties',
        () async {
      final ikA = await _x25519();
      final ekA = await _x25519();
      final ikB = await _x25519();
      final spkB = await _x25519();
      final opkB = await _x25519();

      final withOpk = await X3dh.deriveSender(
        identityKeyPair: ikA,
        ephemeralKeyPair: ekA,
        recipientIdentityPub: _pubOf(ikB),
        recipientSignedPrekeyPub: _pubOf(spkB),
        recipientOneTimePub: _pubOf(opkB),
      );
      final withoutOpk = await X3dh.deriveSender(
        identityKeyPair: ikA,
        ephemeralKeyPair: ekA,
        recipientIdentityPub: _pubOf(ikB),
        recipientSignedPrekeyPub: _pubOf(spkB),
        recipientOneTimePub: null,
      );
      expect(await withOpk.extractBytes(),
          isNot(equals(await withoutOpk.extractBytes())));
    });

    test('a fresh ephemeral yields a different key (per-message FS)',
        () async {
      final ikA = await _x25519();
      final ikB = await _x25519();
      final spkB = await _x25519();
      final opkB = await _x25519();

      final ek1 = await _x25519();
      final ek2 = await _x25519();
      final k1 = await X3dh.deriveSender(
        identityKeyPair: ikA,
        ephemeralKeyPair: ek1,
        recipientIdentityPub: _pubOf(ikB),
        recipientSignedPrekeyPub: _pubOf(spkB),
        recipientOneTimePub: _pubOf(opkB),
      );
      final k2 = await X3dh.deriveSender(
        identityKeyPair: ikA,
        ephemeralKeyPair: ek2,
        recipientIdentityPub: _pubOf(ikB),
        recipientSignedPrekeyPub: _pubOf(spkB),
        recipientOneTimePub: _pubOf(opkB),
      );
      expect(await k1.extractBytes(), isNot(equals(await k2.extractBytes())));
    });

    test('wrong receiver key fails to reproduce the sender key', () async {
      final ikA = await _x25519();
      final ekA = await _x25519();
      final ikB = await _x25519();
      final spkB = await _x25519();
      final opkB = await _x25519();
      final stranger = await _x25519(); // wrong identity

      final sk = await X3dh.deriveSender(
        identityKeyPair: ikA,
        ephemeralKeyPair: ekA,
        recipientIdentityPub: _pubOf(ikB),
        recipientSignedPrekeyPub: _pubOf(spkB),
        recipientOneTimePub: _pubOf(opkB),
      );
      final wrong = await X3dh.deriveReceiver(
        identityKeyPair: stranger,
        signedPrekeyPair: spkB,
        oneTimeKeyPair: opkB,
        senderIdentityPub: _pubOf(ikA),
        senderEphemeralPub: _pubOf(ekA),
      );
      expect(await sk.extractBytes(), isNot(equals(await wrong.extractBytes())));
    });
  });

  group('PrekeyStore', () {
    Future<PrekeyStore> _store() async {
      final ik = await _x25519();
      final ed = await _ed25519();
      return PrekeyStore(
        identityKeyPair: ik,
        identityPub: _pubOf(ik),
        signKeyPair: ed.kp,
      );
    }

    test('rotate + replenish populates the public bundle', () async {
      final s = await _store();
      await s.rotateSignedPrekey();
      await s.replenishOneTime(5);
      final bundle = s.publicBundle();
      expect(bundle.oneTimePrekeys.length, 5);
      expect(bundle.hasOneTime, isTrue);
      expect(bundle.signedPrekeyPub.length, 32);
      expect(bundle.identityPub, equals(s.identityPub));
    });

    test('publicBundle without a signed prekey throws', () async {
      final s = await _store();
      expect(() => s.publicBundle(), throwsStateError);
    });

    test('signed prekey signature verifies against the identity', () async {
      final ik = await _x25519();
      final ed = await _ed25519();
      final s = PrekeyStore(
        identityKeyPair: ik,
        identityPub: _pubOf(ik),
        signKeyPair: ed.kp,
      );
      await s.rotateSignedPrekey();
      final b = s.publicBundle();
      final ok = await PrekeyStore.verifySignedPrekey(
        signedPrekeyPub: b.signedPrekeyPub,
        signature: b.signedPrekeySig,
        signerEd25519Pub: ed.pub,
      );
      expect(ok, isTrue);
    });

    test('a forged signed-prekey signature fails verification', () async {
      final s = await _store();
      await s.rotateSignedPrekey();
      final b = s.publicBundle();
      final tampered = Uint8List.fromList(b.signedPrekeySig);
      tampered[0] ^= 0xFF;
      final imposterEd = await _ed25519();
      final ok = await PrekeyStore.verifySignedPrekey(
        signedPrekeyPub: b.signedPrekeyPub,
        signature: tampered,
        signerEd25519Pub: imposterEd.pub,
      );
      expect(ok, isFalse);
    });

    test('consumeOneTime deletes the key (forward secrecy)', () async {
      final s = await _store();
      await s.rotateSignedPrekey();
      await s.replenishOneTime(3);
      expect(s.oneTimeCount, 3);
      final id = s.publicBundle().oneTimePrekeys.keys.first;

      final consumed = s.consumeOneTime(id);
      expect(consumed, isNotNull);
      expect(s.oneTimeCount, 2);
      // Gone for good — a replayed message referencing the same id finds
      // nothing, so it can't be silently decrypted again.
      expect(s.consumeOneTime(id), isNull);
      expect(s.oneTimeById(id), isNull);
    });

    test('end-to-end: store-issued bundle drives a matching X3DH key',
        () async {
      // Bob publishes a bundle; Alice uses it; Bob consumes the OPK and
      // reproduces the same key.
      final bob = await _store();
      await bob.rotateSignedPrekey();
      await bob.replenishOneTime(2);
      final bundle = bob.publicBundle();

      final ikA = await _x25519();
      final ekA = await _x25519();
      final opkId = bundle.oneTimePrekeys.keys.first;

      final senderKey = await X3dh.deriveSender(
        identityKeyPair: ikA,
        ephemeralKeyPair: ekA,
        recipientIdentityPub: bundle.identityPub,
        recipientSignedPrekeyPub: bundle.signedPrekeyPub,
        recipientOneTimePub: bundle.oneTimePrekeys[opkId],
      );

      final opk = bob.consumeOneTime(opkId)!;
      final receiverKey = await X3dh.deriveReceiver(
        identityKeyPair: bob.identityKeyPair,
        signedPrekeyPair: bob.currentSignedPrekey!.keyPair,
        oneTimeKeyPair: opk.keyPair,
        senderIdentityPub: _pubOf(ikA),
        senderEphemeralPub: _pubOf(ekA),
      );

      expect(await senderKey.extractBytes(),
          equals(await receiverKey.extractBytes()));
    });
  });
}
