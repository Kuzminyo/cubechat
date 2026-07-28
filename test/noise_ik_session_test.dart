import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/crypto/identity_keys.dart';
import 'package:cubechat/core/crypto/noise/noise_session.dart';
import 'package:cubechat/core/transport/chat_session.dart';
import 'package:cubechat/core/transport/frame.dart';
import 'package:flutter_test/flutter_test.dart';

/// Same shape the XX tests mint: Noise only uses the X25519 half, but the
/// constructor asserts on the Ed25519 fields too.
Future<IdentityKeys> _identity() async {
  final pair = await X25519().newKeyPair();
  final priv = Uint8List.fromList(await pair.extractPrivateKeyBytes());
  final pub = await pair.extractPublicKey();
  final edPair = await Ed25519().newKeyPair();
  final edSeed = Uint8List.fromList(await edPair.extractPrivateKeyBytes());
  final edPub = await edPair.extractPublicKey();
  return IdentityKeys(
    publicKey: Uint8List.fromList(pub.bytes),
    privateKey: priv,
    signPublicKey: Uint8List.fromList(edPub.bytes),
    signPrivateKey: edSeed,
  );
}

void main() {
  group('IK through the session layer', () {
    test('two messages establish, and the frames are labelled IK', () async {
      final alice = await _identity();
      final bob = await _identity();

      final initiator = await ChatSession.initiateIk(
        peerId: 'dev-1',
        peerLabel: 'Bob',
        identity: alice,
        remoteStatic: Uint8List.fromList(bob.publicKey),
      );
      final responder = await ChatSession.respondIk(
        peerId: 'dev-0',
        peerLabel: 'Alice',
        identity: bob,
      );

      expect(initiator.pattern, NoisePattern.ik);
      expect(responder.pattern, NoisePattern.ik);

      final msg1 = await initiator.nextHandshakeFrame();
      expect(msg1, isNotNull);
      expect(msg1!.type, FrameType.noiseIk1);

      final msg2 = await responder.handleHandshakeFrame(msg1);
      expect(msg2, isNotNull);
      expect(msg2!.type, FrameType.noiseIk2);
      expect(responder.isEstablished, isTrue,
          reason: 'the responder is done once it has written message 2');

      final none = await initiator.handleHandshakeFrame(msg2);
      expect(none, isNull, reason: 'IK has no third message');
      expect(initiator.isEstablished, isTrue);
    });

    test('both sides end up on the same identity', () async {
      final alice = await _identity();
      final bob = await _identity();

      final initiator = await ChatSession.initiateIk(
        peerId: 'dev-1',
        peerLabel: 'Bob',
        identity: alice,
        remoteStatic: Uint8List.fromList(bob.publicKey),
      );
      final responder = await ChatSession.respondIk(
        peerId: 'dev-0',
        peerLabel: 'Alice',
        identity: bob,
      );
      await initiator
          .handleHandshakeFrame((await responder.handleHandshakeFrame(
        (await initiator.nextHandshakeFrame())!,
      ))!);

      expect(initiator.remoteStaticPublicKey, equals(bob.publicKey));
      expect(responder.remoteStaticPublicKey, equals(alice.publicKey));
    });

    test('an established IK session carries a message', () async {
      final alice = await _identity();
      final bob = await _identity();
      final initiator = await ChatSession.initiateIk(
        peerId: 'dev-1',
        peerLabel: 'Bob',
        identity: alice,
        remoteStatic: Uint8List.fromList(bob.publicKey),
      );
      final responder = await ChatSession.respondIk(
        peerId: 'dev-0',
        peerLabel: 'Alice',
        identity: bob,
      );
      await initiator
          .handleHandshakeFrame((await responder.handleHandshakeFrame(
        (await initiator.nextHandshakeFrame())!,
      ))!);

      final frame = await initiator.encryptText('hello over IK');
      expect(frame.type, FrameType.transport);
      expect(await responder.decryptText(frame), 'hello over IK');
    });

    test('a caller with the wrong key gets no session and no reply', () async {
      final bob = await _identity();
      final stranger = await _identity();
      final somebodyElse = await _identity();

      // The stranger addresses a key that is not Bob's.
      final initiator = await ChatSession.initiateIk(
        peerId: 'dev-1',
        peerLabel: 'Bob',
        identity: stranger,
        remoteStatic: Uint8List.fromList(somebodyElse.publicKey),
      );
      final responder = await ChatSession.respondIk(
        peerId: 'dev-0',
        peerLabel: 'stranger',
        identity: bob,
      );

      final reply = await responder
          .handleHandshakeFrame((await initiator.nextHandshakeFrame())!);

      expect(reply, isNull, reason: 'nothing is sent back to a wrong opener');
      expect(responder.isEstablished, isFalse);
      expect(responder.remoteStaticPublicKey, isNull);
      expect(responder.status, ChatSessionStatus.failed);
    });

    test('XX still works and still labels its frames XX', () async {
      final alice = await _identity();
      final bob = await _identity();
      final initiator = await ChatSession.initiate(
        peerId: 'dev-1',
        peerLabel: 'Bob',
        identity: alice,
      );
      final responder = await ChatSession.respond(
        peerId: 'dev-0',
        peerLabel: 'Alice',
        identity: bob,
      );
      expect(initiator.pattern, NoisePattern.xx);

      final hs1 = await initiator.nextHandshakeFrame();
      expect(hs1!.type, FrameType.noiseHandshake1);
      final hs2 = await responder.handleHandshakeFrame(hs1);
      expect(hs2!.type, FrameType.noiseHandshake2);
      final hs3 = await initiator.handleHandshakeFrame(hs2);
      expect(hs3!.type, FrameType.noiseHandshake3);
      await responder.handleHandshakeFrame(hs3);

      expect(initiator.isEstablished, isTrue);
      expect(responder.isEstablished, isTrue);
    });
  });
}
