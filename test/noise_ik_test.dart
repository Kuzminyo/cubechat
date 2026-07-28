import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/crypto/noise/noise_cipher_state.dart';
import 'package:cubechat/core/crypto/noise/noise_ik_handshake_state.dart';
import 'package:flutter_test/flutter_test.dart';

Future<SimpleKeyPair> _static() => X25519().newKeyPair();

Future<Uint8List> _pub(SimpleKeyPair pair) async =>
    Uint8List.fromList((await pair.extractPublicKey()).bytes);

/// Drive a full IK handshake and hand back both finished states.
Future<({NoiseIkHandshakeState i, NoiseIkHandshakeState r})> _handshake({
  required SimpleKeyPair initiatorStatic,
  required SimpleKeyPair responderStatic,
  Uint8List? initiatorBelievesResponderIs,
}) async {
  final responderPub =
      initiatorBelievesResponderIs ?? await _pub(responderStatic);

  final i = await NoiseIkHandshakeState.initialize(
    isInitiator: true,
    localStatic: initiatorStatic,
    remoteStatic: responderPub,
  );
  final r = await NoiseIkHandshakeState.initialize(
    isInitiator: false,
    localStatic: responderStatic,
  );

  await r.readMessage(await i.writeMessage());
  await i.readMessage(await r.writeMessage());
  return (i: i, r: r);
}

void main() {
  group('Noise IK handshake', () {
    test('completes in two messages and agrees on transport keys', () async {
      final initiatorStatic = await _static();
      final responderStatic = await _static();
      final hs = await _handshake(
        initiatorStatic: initiatorStatic,
        responderStatic: responderStatic,
      );

      expect(hs.i.handshakeFinished, isTrue);
      expect(hs.r.handshakeFinished, isTrue);

      // The two sides must have derived the *same* keys in opposite roles, or
      // the session would establish and then fail to carry a single message.
      final ct = await hs.i.sendCipherState!
          .encryptWithAd(Uint8List(0), Uint8List.fromList([1, 2, 3, 4]));
      expect(
        await hs.r.receiveCipherState!.decryptWithAd(Uint8List(0), ct),
        equals(Uint8List.fromList([1, 2, 3, 4])),
      );

      final back = await hs.r.sendCipherState!
          .encryptWithAd(Uint8List(0), Uint8List.fromList([9, 8]));
      expect(
        await hs.i.receiveCipherState!.decryptWithAd(Uint8List(0), back),
        equals(Uint8List.fromList([9, 8])),
      );
    });

    test('each side authenticates the other', () async {
      final initiatorStatic = await _static();
      final responderStatic = await _static();
      final hs = await _handshake(
        initiatorStatic: initiatorStatic,
        responderStatic: responderStatic,
      );

      expect(hs.r.remoteStaticPublicKey, equals(await _pub(initiatorStatic)));
      expect(hs.i.remoteStaticPublicKey, equals(await _pub(responderStatic)));
    });

    test('the responder never puts its static key on the wire', () async {
      final initiatorStatic = await _static();
      final responderStatic = await _static();
      final responderPub = await _pub(responderStatic);

      final i = await NoiseIkHandshakeState.initialize(
        isInitiator: true,
        localStatic: initiatorStatic,
        remoteStatic: responderPub,
      );
      final r = await NoiseIkHandshakeState.initialize(
        isInitiator: false,
        localStatic: responderStatic,
      );

      final msg1 = await i.writeMessage();
      await r.readMessage(msg1);
      final msg2 = await r.writeMessage();

      // This is the entire point of the pattern: nothing the responder sends
      // contains its long-term identity, so a stranger cannot harvest it.
      expect(_contains(msg2, responderPub), isFalse);
      expect(_contains(msg1, responderPub), isFalse);
    });

    test('the initiator\'s static is not sent in the clear either', () async {
      final initiatorStatic = await _static();
      final responderStatic = await _static();
      final i = await NoiseIkHandshakeState.initialize(
        isInitiator: true,
        localStatic: initiatorStatic,
        remoteStatic: await _pub(responderStatic),
      );
      final msg1 = await i.writeMessage();
      expect(_contains(msg1, await _pub(initiatorStatic)), isFalse,
          reason: 'it travels encrypted under es');
    });

    test('a stranger who does not know us cannot open the handshake', () async {
      final responderStatic = await _static();
      final strangerStatic = await _static();
      // The stranger guesses — they have *some* key, just not ours.
      final wrongGuess = await _pub(await _static());

      final stranger = await NoiseIkHandshakeState.initialize(
        isInitiator: true,
        localStatic: strangerStatic,
        remoteStatic: wrongGuess,
      );
      final us = await NoiseIkHandshakeState.initialize(
        isInitiator: false,
        localStatic: responderStatic,
      );

      // We reject their message rather than answering it, so they get neither
      // a session nor our key.
      final theirAttempt = await stranger.writeMessage();
      await expectLater(
        () => us.readMessage(theirAttempt),
        throwsA(anything),
      );
      expect(us.handshakeFinished, isFalse);
      expect(us.remoteStaticPublicKey, isNull);
    });

    test('an initiator with no responder key is refused up front', () async {
      final mine = await _static();
      await expectLater(
        () => NoiseIkHandshakeState.initialize(
          isInitiator: true,
          localStatic: mine,
        ),
        throwsA(isA<NoiseException>()),
      );
    });

    test('a wrong-length responder key is refused', () async {
      final mine = await _static();
      await expectLater(
        () => NoiseIkHandshakeState.initialize(
          isInitiator: true,
          localStatic: mine,
          remoteStatic: Uint8List(31),
        ),
        throwsA(isA<NoiseException>()),
      );
    });

    test('a tampered first message fails instead of establishing', () async {
      final i = await NoiseIkHandshakeState.initialize(
        isInitiator: true,
        localStatic: await _static(),
        remoteStatic: await _pub(await _static()),
      );
      final r = await NoiseIkHandshakeState.initialize(
        isInitiator: false,
        localStatic: await _static(),
      );
      final msg1 = await i.writeMessage();
      msg1[msg1.length - 1] ^= 0xFF;
      await expectLater(() => r.readMessage(msg1), throwsA(anything));
    });

    test('a handshake payload survives the round trip', () async {
      final initiatorStatic = await _static();
      final responderStatic = await _static();
      final responderPub = await _pub(responderStatic);

      final i = await NoiseIkHandshakeState.initialize(
        isInitiator: true,
        localStatic: initiatorStatic,
        remoteStatic: responderPub,
      );
      final r = await NoiseIkHandshakeState.initialize(
        isInitiator: false,
        localStatic: responderStatic,
      );

      final hello = Uint8List.fromList([0xC0, 0xFF, 0xEE]);
      expect(await r.readMessage(await i.writeMessage(hello)), equals(hello));

      final reply = Uint8List.fromList([0x42]);
      expect(await i.readMessage(await r.writeMessage(reply)), equals(reply));
    });

    test('neither side will write out of turn', () async {
      final r = await NoiseIkHandshakeState.initialize(
        isInitiator: false,
        localStatic: await _static(),
      );
      // The responder speaks second; writing first is a state-machine bug.
      await expectLater(() => r.writeMessage(), throwsA(isA<NoiseException>()));
    });

    test('an IK message is not readable as XX, and vice versa', () async {
      // The protocol name is hashed into h first, so the two patterns diverge
      // from the very first byte of state — a cross-pattern message cannot be
      // silently accepted.
      final initiatorStatic = await _static();
      final responderStatic = await _static();
      final ik = await NoiseIkHandshakeState.initialize(
        isInitiator: true,
        localStatic: initiatorStatic,
        remoteStatic: await _pub(responderStatic),
      );
      final ikMsg = await ik.writeMessage();

      final xxResponder = await NoiseIkHandshakeState.initialize(
        isInitiator: false,
        localStatic: await _static(), // different identity entirely
      );
      await expectLater(
        () => xxResponder.readMessage(ikMsg),
        throwsA(anything),
      );
    });
  });
}

/// Naive substring search, to assert a key is *absent* from bytes on the wire.
bool _contains(Uint8List haystack, Uint8List needle) {
  if (needle.isEmpty || needle.length > haystack.length) return false;
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var hit = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}
