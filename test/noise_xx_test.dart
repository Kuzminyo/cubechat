import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/crypto/identity_keys.dart';
import 'package:cubechat/core/crypto/noise/noise_cipher_state.dart';
import 'package:cubechat/core/crypto/noise/noise_session.dart';
import 'package:flutter_test/flutter_test.dart';

Future<IdentityKeys> _mintIdentity() async {
  final x25519 = X25519();
  final pair = await x25519.newKeyPair();
  final priv = Uint8List.fromList(await pair.extractPrivateKeyBytes());
  final pub = await pair.extractPublicKey();
  // Tests of Noise only exercise the X25519 side, but the IdentityKeys
  // shape now requires Ed25519 fields too — mint a paired Ed25519 keypair
  // just so the constructor's assertions pass.
  final edPair = await Ed25519().newKeyPair();
  final edSeed =
      Uint8List.fromList(await edPair.extractPrivateKeyBytes());
  final edPub = await edPair.extractPublicKey();
  return IdentityKeys(
    publicKey: Uint8List.fromList(pub.bytes),
    privateKey: priv,
    signPublicKey: Uint8List.fromList(edPub.bytes),
    signPrivateKey: edSeed,
  );
}

void main() {
  group('Noise XX', () {
    test('full roundtrip — initiator and responder authenticate each other', () async {
      final aliceId = await _mintIdentity();
      final bobId = await _mintIdentity();

      final alice = await NoiseSession.initiate(aliceId);
      final bob = await NoiseSession.respond(bobId);

      // -> e
      final m1 = await alice.writeHandshake();
      await bob.readHandshake(m1);

      // <- e, ee, s, es
      final m2 = await bob.writeHandshake();
      await alice.readHandshake(m2);

      // -> s, se
      final m3 = await alice.writeHandshake();
      await bob.readHandshake(m3);

      expect(alice.established, isTrue);
      expect(bob.established, isTrue);

      // Mutual authentication — each side learned the other's public key.
      expect(alice.remoteStaticPublicKey, equals(bobId.publicKey));
      expect(bob.remoteStaticPublicKey, equals(aliceId.publicKey));
    });

    test('transport messages encrypt and decrypt in both directions', () async {
      final (alice, bob) = await _runHandshake();

      final outbound = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final ct = await alice.encrypt(outbound);
      final pt = await bob.decrypt(ct);
      expect(pt, equals(outbound));

      final reply = Uint8List.fromList('hello back'.codeUnits);
      final rct = await bob.encrypt(reply);
      final rpt = await alice.decrypt(rct);
      expect(rpt, equals(reply));
    });

    test('multiple transport messages — nonce counter advances independently', () async {
      final (alice, bob) = await _runHandshake();

      for (var i = 0; i < 10; i++) {
        final msg = Uint8List.fromList([i, i + 1, i + 2]);
        final ct = await alice.encrypt(msg);
        expect(await bob.decrypt(ct), equals(msg));
      }
      for (var i = 0; i < 10; i++) {
        final msg = Uint8List.fromList([100 + i]);
        final ct = await bob.encrypt(msg);
        expect(await alice.decrypt(ct), equals(msg));
      }
    });

    test('handshake carries payload on the third message', () async {
      final aliceId = await _mintIdentity();
      final bobId = await _mintIdentity();

      final alice = await NoiseSession.initiate(aliceId);
      final bob = await NoiseSession.respond(bobId);

      await bob.readHandshake(await alice.writeHandshake());
      await alice.readHandshake(await bob.writeHandshake());

      final payload = Uint8List.fromList('hello on m3'.codeUnits);
      final m3 = await alice.writeHandshake(payload);
      final received = await bob.readHandshake(m3);

      expect(received, equals(payload));
      expect(alice.established, isTrue);
      expect(bob.established, isTrue);
    });

    test('mutated ciphertext fails authentication', () async {
      final (alice, bob) = await _runHandshake();

      final ct = await alice.encrypt(Uint8List.fromList([42, 42, 42]));
      // Flip one byte in the middle of the ciphertext.
      ct[1] ^= 0xFF;
      expect(() => bob.decrypt(ct), throwsA(isA<NoiseException>()));
    });
  });

  test('fingerprint formatting groups hex into 4-char chunks', () {
    final bytes = Uint8List.fromList(List.generate(16, (i) => i));
    final formatted = IdentityKeys.formatFingerprint(bytes);
    expect(formatted, '0001 0203 0405 0607 0809 0a0b 0c0d 0e0f');
  });
}

Future<(NoiseSession, NoiseSession)> _runHandshake() async {
  final aliceId = await _mintIdentity();
  final bobId = await _mintIdentity();

  final alice = await NoiseSession.initiate(aliceId);
  final bob = await NoiseSession.respond(bobId);

  await bob.readHandshake(await alice.writeHandshake());
  await alice.readHandshake(await bob.writeHandshake());
  await bob.readHandshake(await alice.writeHandshake());

  return (alice, bob);
}
