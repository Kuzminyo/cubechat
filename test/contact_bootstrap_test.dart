import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/crypto/sealed_box.dart';
import 'package:cubechat/core/transport/announcement.dart';
import 'package:cubechat/core/transport/contact_card.dart';
import 'package:cubechat/core/transport/envelope.dart';
import 'package:cubechat/core/transport/frame.dart';
import 'package:cubechat/core/transport/nostr/nostr_frame_codec.dart';
import 'package:flutter_test/flutter_test.dart';

/// The cold-start path: two people who have never been in Bluetooth range of
/// each other, and therefore have never exchanged the signed announcement the
/// mesh relies on.
///
/// Alice hands Bob a contact card through some other app. That gets Bob far
/// enough to encrypt *to* Alice, but Alice still holds nothing of Bob's — and
/// an inbound frame carries only an 8-byte origin hash, which cannot be
/// reversed into an identity. So the first thing cubechat puts on the relay is
/// the same self-authenticating announcement the mesh broadcasts. These tests
/// pin that hand-off end to end, at the wire layer, without needing a phone.
Future<({SimpleKeyPairData kp, Uint8List pub})> _newEd() async {
  final pair = await Ed25519().newKeyPair();
  final pub = await pair.extractPublicKey();
  final seed = await pair.extractPrivateKeyBytes();
  return (
    kp: SimpleKeyPairData(seed, publicKey: pub, type: KeyPairType.ed25519),
    pub: Uint8List.fromList(pub.bytes),
  );
}

Uint8List _key(int base) =>
    Uint8List.fromList(List.generate(32, (i) => (base + i) & 0xFF));

/// Naive substring search — used to assert a secret is *absent* from bytes we
/// are about to hand a public relay.
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

/// Mirrors `MessagingService._announcementFrame`: a signed announcement in a
/// broadcast envelope, wrapped in a peerAnnouncement frame.
Frame _announcementFrame({
  required Uint8List signedBody,
  required Uint8List originHash,
  required int ttl,
}) {
  final env = TransportEnvelope(
    originPubkeyHash: originHash,
    destPubkeyHash: TransportEnvelope.broadcastDest(),
    msgId: TransportEnvelope.newMsgId(),
    ttl: ttl,
    body: signedBody,
  );
  return Frame(type: FrameType.peerAnnouncement, payload: env.encode());
}

void main() {
  group('off-mesh first contact', () {
    test('a card carries everything needed to address someone', () async {
      final alice = await _newEd();
      final aliceX = _key(1);
      final aliceNpub = _key(200);
      final ann = PeerAnnouncement(
        pubkey: aliceX,
        signPubkey: alice.pub,
        signedPrekeyPub: _key(70),
        nostrPubkey: aliceNpub,
        nickname: 'Alice',
      );

      // Alice copies her card; it travels through some other messenger.
      final card = ContactCard.encode(await ann.sign(alice.kp));

      // Bob pastes it. He now holds an encryption key, a verifying key, a
      // prekey for forward secrecy, and — the part that makes the internet
      // path possible at all — a relay address to publish to.
      final asBobSeesIt = await ContactCard.parse(card);
      expect(asBobSeesIt.pubkey, equals(aliceX));
      expect(asBobSeesIt.nostrPubkey, equals(aliceNpub));
      expect(asBobSeesIt.signedPrekeyPub, equals(_key(70)));
    });

    test('an introduction survives the relay wire and verifies', () async {
      final bob = await _newEd();
      final bobAnn = PeerAnnouncement(
        pubkey: _key(9),
        signPubkey: bob.pub,
        signedPrekeyPub: _key(90),
        nostrPubkey: _key(150),
        nickname: 'Bob',
      );
      final signedBody = await bobAnn.sign(bob.kp);
      final originHash = TransportEnvelope.shortHashFromHashBytes(
        Uint8List.fromList((await Blake2s().hash(_key(9))).bytes),
      );

      // Bob answers Alice, so his announcement rides out to her npub first.
      final frame = _announcementFrame(
        signedBody: signedBody,
        originHash: originHash,
        ttl: 1,
      );
      final content = NostrFrameCodec.encodeContent(frame.encode());

      // ...and comes back out of the relay on Alice's side.
      final recovered = NostrFrameCodec.decodeContent(content);
      expect(recovered, isNotNull);
      final inbound = Frame.decode(recovered!);
      expect(inbound.type, FrameType.peerAnnouncement);

      final env = TransportEnvelope.decode(inbound.payload);
      expect(env.isBroadcast, isTrue);
      final decoded = await PeerAnnouncement.verifyAndDecode(env.body);
      expect(decoded.nickname, 'Bob');
      expect(decoded.nostrPubkey, equals(_key(150)));
      expect(decoded.pubkey, equals(_key(9)));
    });

    test('an introduction is point-to-point, not flooded onto the mesh',
        () async {
      final bob = await _newEd();
      final ann = PeerAnnouncement(
        pubkey: _key(9),
        signPubkey: bob.pub,
        signedPrekeyPub: _key(90),
        nostrPubkey: _key(150),
        nickname: 'Bob',
      );
      final frame = _announcementFrame(
        signedBody: await ann.sign(bob.kp),
        originHash: Uint8List(TransportEnvelope.hashLen),
        ttl: 1,
      );

      // The receiver forwards only while the decremented ttl is still alive.
      // At ttl 1 that lands on 0, so a relay-delivered introduction stops with
      // the person it was addressed to instead of being re-broadcast across
      // their local Bluetooth neighbourhood.
      final env = TransportEnvelope.decode(frame.payload);
      expect(env.ttl, 1);
      expect(env.decrementTtl().ttl, 0);
    });

    test('a mesh announcement still gets the full hop budget', () async {
      final ed = await _newEd();
      final ann = PeerAnnouncement(
        pubkey: _key(9),
        signPubkey: ed.pub,
        signedPrekeyPub: _key(90),
        nostrPubkey: _key(150),
        nickname: 'Bob',
      );
      final frame = _announcementFrame(
        signedBody: await ann.sign(ed.kp),
        originHash: Uint8List(TransportEnvelope.hashLen),
        ttl: TransportEnvelope.defaultTtl,
      );
      final env = TransportEnvelope.decode(frame.payload);
      expect(env.ttl, TransportEnvelope.defaultTtl);
      expect(env.decrementTtl().ttl, greaterThan(0));
    });

    test('a relay introduction is sealed, so the relay learns no name',
        () async {
      // Alice's encryption key — the one Bob got from her contact card.
      final kp = await X25519().newKeyPair();
      final alicePub =
          Uint8List.fromList((await kp.extractPublicKey()).bytes);
      final aliceKeyPair = SimpleKeyPairData(
        await kp.extractPrivateKeyBytes(),
        publicKey: await kp.extractPublicKey(),
        type: KeyPairType.x25519,
      );

      final bob = await _newEd();
      final ann = PeerAnnouncement(
        pubkey: _key(9),
        signPubkey: bob.pub,
        signedPrekeyPub: _key(90),
        nostrPubkey: _key(150),
        nickname: 'Bob',
      );
      final signedBody = await ann.sign(bob.kp);

      // What actually goes on the wire: [0x01][SealedBox to Alice].
      final sealed = await SealedBox.seal(signedBody, alicePub);
      final body = Uint8List(1 + sealed.length)
        ..[0] = 0x01
        ..setRange(1, 1 + sealed.length, sealed);
      final frame = _announcementFrame(
        signedBody: body,
        originHash: Uint8List(TransportEnvelope.hashLen),
        ttl: 1,
      );

      // A scraper reading the relay sees no nickname and no keys in the clear.
      final onTheWire = frame.encode();
      expect(
        _contains(onTheWire, Uint8List.fromList('Bob'.codeUnits)),
        isFalse,
        reason: 'a public relay must not learn who this npub belongs to',
      );
      expect(_contains(onTheWire, _key(90)), isFalse);

      // Alice opens it and learns Bob exactly as a mesh announcement would.
      final env = TransportEnvelope.decode(frame.payload);
      expect(env.body[0], 0x01);
      final opened = await SealedBox.open(
        Uint8List.sublistView(env.body, 1),
        recipientKeyPair: aliceKeyPair,
        recipientPubkey: alicePub,
      );
      final decoded = await PeerAnnouncement.verifyAndDecode(opened);
      expect(decoded.nickname, 'Bob');
      expect(decoded.nostrPubkey, equals(_key(150)));
    });

    test('a sealed introduction addressed to someone else is unreadable',
        () async {
      final aliceKp = await X25519().newKeyPair();
      final alicePub =
          Uint8List.fromList((await aliceKp.extractPublicKey()).bytes);

      final eveKp = await X25519().newKeyPair();
      final evePub =
          Uint8List.fromList((await eveKp.extractPublicKey()).bytes);
      final eveKeyPair = SimpleKeyPairData(
        await eveKp.extractPrivateKeyBytes(),
        publicKey: await eveKp.extractPublicKey(),
        type: KeyPairType.x25519,
      );

      final bob = await _newEd();
      final ann = PeerAnnouncement(
        pubkey: _key(9),
        signPubkey: bob.pub,
        signedPrekeyPub: _key(90),
        nostrPubkey: _key(150),
        nickname: 'Bob',
      );
      final sealed = await SealedBox.seal(await ann.sign(bob.kp), alicePub);

      await expectLater(
        () => SealedBox.open(
          sealed,
          recipientKeyPair: eveKeyPair,
          recipientPubkey: evePub,
        ),
        throwsA(isA<Object>()),
      );
    });

    test('a tampered introduction is rejected before it reaches the roster',
        () async {
      final bob = await _newEd();
      final ann = PeerAnnouncement(
        pubkey: _key(9),
        signPubkey: bob.pub,
        signedPrekeyPub: _key(90),
        nostrPubkey: _key(150),
        nickname: 'Bob',
      );
      final signedBody = await ann.sign(bob.kp);
      // A relay swaps in its own Nostr address to intercept the reply path.
      signedBody[1 + 32 + 32 + 32] ^= 0x0F;

      final frame = _announcementFrame(
        signedBody: signedBody,
        originHash: Uint8List(TransportEnvelope.hashLen),
        ttl: 1,
      );
      final env = TransportEnvelope.decode(frame.payload);
      await expectLater(
        () => PeerAnnouncement.verifyAndDecode(env.body),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
