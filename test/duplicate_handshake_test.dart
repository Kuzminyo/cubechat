import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/crypto/identity_keys.dart';
import 'package:cubechat/core/transport/chat_session.dart';
import 'package:cubechat/core/transport/frame.dart';
import 'package:flutter_test/flutter_test.dart';

/// Same shape the other Noise tests mint.
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

/// A pair of IK sessions that have finished their handshake, plus the two
/// frames that got them there — the ones a duplicate would be a copy of.
class _Established {
  _Established(this.initiator, this.responder, this.msg1, this.msg2);

  final ChatSession initiator;
  final ChatSession responder;
  final Frame msg1;
  final Frame msg2;
}

Future<_Established> _handshake() async {
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

  final msg1 = (await initiator.nextHandshakeFrame())!;
  final msg2 = (await responder.handleHandshakeFrame(msg1))!;
  await initiator.handleHandshakeFrame(msg2);

  expect(initiator.isEstablished, isTrue);
  expect(responder.isEstablished, isTrue);
  return _Established(initiator, responder, msg1, msg2);
}

void main() {
  group('a duplicate handshake frame on an established session', () {
    // The mesh delivers these routinely. One phone is visible through several
    // BLE addresses at once (privacy-address rotation), and the reply can come
    // back over our central link *and* over their write to our peripheral — so
    // a second copy of IK2 landing a millisecond after the first is ordinary
    // traffic, not an attack and not a fault.
    //
    // It used to be fatal: the copy went into readMessage, which threw
    // "handshake already finished", and the catch marked a working session
    // failed. The link stayed up and stayed usable, and the session on top of
    // it was written off — after which the handshake watchdog took the link
    // down too, and messages to that peer went out over whatever mesh route
    // was left, or nowhere.
    test('leaves the initiator established', () async {
      final s = await _handshake();

      final reply = await s.initiator.handleHandshakeFrame(s.msg2);

      expect(reply, isNull, reason: 'nothing to answer — IK has two messages');
      expect(
        s.initiator.isEstablished,
        isTrue,
        reason: 'a repeat of a frame we already handled is not a failure',
      );
      expect(s.initiator.status, ChatSessionStatus.established);
    });

    test('leaves the responder established', () async {
      final s = await _handshake();

      final reply = await s.responder.handleHandshakeFrame(s.msg1);

      expect(reply, isNull);
      expect(s.responder.isEstablished, isTrue);
      expect(s.responder.status, ChatSessionStatus.established);
    });

    test('leaves the transport keys usable', () async {
      final s = await _handshake();

      // The duplicate must not consume, advance or clear any Noise state: the
      // session has to keep encrypting and decrypting exactly as it would have
      // if the frame had never arrived. This is the assertion that actually
      // matters — `established` is only a label on top of it.
      await s.initiator.handleHandshakeFrame(s.msg2);
      await s.responder.handleHandshakeFrame(s.msg1);

      final sent = await s.initiator.encryptText('still here');
      expect(await s.responder.decryptText(sent), 'still here');

      final back = await s.responder.encryptText('so am I');
      expect(await s.initiator.decryptText(back), 'so am I');
    });

    test('survives a garbage frame too', () async {
      final s = await _handshake();

      // Not a copy of anything — bytes that cannot be read as a handshake at
      // all. Anyone who can write to the characteristic can send this, so an
      // established session must not be losable to one.
      final junk = Frame(
        type: FrameType.noiseIk2,
        payload: Uint8List.fromList(List<int>.filled(48, 0x41)),
      );
      await s.initiator.handleHandshakeFrame(junk);

      expect(s.initiator.isEstablished, isTrue);
      final sent = await s.initiator.encryptText('unbothered');
      expect(await s.responder.decryptText(sent), 'unbothered');
    });
  });
}
