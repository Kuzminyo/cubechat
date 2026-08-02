import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/identity/avatar_controller.dart';
import 'package:cubechat/core/transport/announcement.dart';
import 'package:cubechat/core/transport/frame_fragment.dart';
import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:cubechat/core/transport/mtu_budget.dart';
import 'package:flutter_test/flutter_test.dart';

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

Future<Uint8List> _sha(Uint8List bytes) async =>
    Uint8List.fromList((await Sha256().hash(bytes)).bytes);

/// Rebuild a v0x04 announcement — the pre-avatar wire format — so the
/// back-compat path is exercised against real bytes rather than a flag.
Future<Uint8List> _signV4({
  required SimpleKeyPairData kp,
  required Uint8List signPub,
  required String nickname,
}) async {
  final name = Uint8List.fromList(nickname.codeUnits);
  final body = Uint8List(1 + 32 * 4 + 1 + name.length);
  var c = 0;
  body[c++] = PeerAnnouncement.versionV4NoAvatar;
  body.setRange(c, c += 32, _key(1));
  body.setRange(c, c += 32, signPub);
  body.setRange(c, c += 32, _key(70));
  body.setRange(c, c += 32, _key(130));
  body[c++] = name.length;
  body.setRange(c, c += name.length, name);
  final sig = await Ed25519().sign(body, keyPair: kp);
  final out = Uint8List(body.length + PeerAnnouncement.sigLen);
  out.setRange(0, body.length, body);
  out.setRange(body.length, out.length, sig.bytes);
  return out;
}

void main() {
  group('announcement carries the avatar digest', () {
    test('a hash survives the round trip and is covered by the signature',
        () async {
      final ed = await _newEd();
      final hash = await _sha(Uint8List.fromList([1, 2, 3]));
      final ann = PeerAnnouncement(
        pubkey: _key(1),
        signPubkey: ed.pub,
        signedPrekeyPub: _key(70),
        nostrPubkey: _key(130),
        nickname: 'Alice',
        avatarHash: hash,
      );
      final wire = await ann.sign(ed.kp);
      final decoded = await PeerAnnouncement.verifyAndDecode(wire);

      expect(decoded.avatarHash, equals(hash));
      expect(decoded.isAvatarAware, isTrue);

      // Flip a bit inside the digest: the signature must no longer verify,
      // which is the whole reason the picture can be trusted later.
      final tampered = Uint8List.fromList(wire);
      final digestAt = tampered.length - PeerAnnouncement.sigLen - 1;
      tampered[digestAt] ^= 0xFF;
      await expectLater(
        PeerAnnouncement.verifyAndDecode(tampered),
        throwsA(isA<FormatException>()),
      );
    });

    test('no picture is distinguishable from an old build that cannot say',
        () async {
      final ed = await _newEd();
      final none = PeerAnnouncement(
        pubkey: _key(1),
        signPubkey: ed.pub,
        signedPrekeyPub: _key(70),
        nostrPubkey: _key(130),
        nickname: 'Alice',
      );
      final decodedNone =
          await PeerAnnouncement.verifyAndDecode(await none.sign(ed.kp));
      expect(decodedNone.avatarHash, isNull);
      expect(decodedNone.isAvatarAware, isTrue,
          reason: 'we said, explicitly, that there is no picture');

      final v4 = await _signV4(
        kp: ed.kp,
        signPub: ed.pub,
        nickname: 'Alice',
      );
      final decodedV4 = await PeerAnnouncement.verifyAndDecode(v4);
      expect(decodedV4.nickname, 'Alice',
          reason: 'an older peer still resolves, minus the avatar');
      expect(decodedV4.avatarHash, isNull);
      expect(decodedV4.isAvatarAware, isFalse,
          reason: 'silence must not be read as a removal');
    });
  });

  group('AvatarPayload', () {
    test('round trips', () {
      final jpeg = Uint8List.fromList(List.generate(4096, (i) => i & 0xFF));
      final decoded = AvatarPayload.decode(AvatarPayload(jpeg: jpeg).encode());
      expect(decoded.jpeg, equals(jpeg));
    });

    test('refuses an empty body, an oversized one, and trailing bytes', () {
      expect(() => AvatarPayload(jpeg: Uint8List(0)),
          throwsA(isA<FormatException>()));
      expect(
        () => AvatarPayload(jpeg: Uint8List(AvatarPayload.maxBytes + 1)),
        throwsA(isA<FormatException>()),
      );

      final wire = AvatarPayload(jpeg: Uint8List.fromList([9, 9, 9])).encode();
      final padded = Uint8List.fromList([...wire, 0]);
      expect(() => AvatarPayload.decode(padded),
          throwsA(isA<FormatException>()));
    });

    test('refuses an unknown version rather than guessing the layout', () {
      final wire = AvatarPayload(jpeg: Uint8List.fromList([1, 2])).encode();
      wire[0] = 0x99;
      expect(
          () => AvatarPayload.decode(wire), throwsA(isA<FormatException>()));
    });
  });

  group('an avatar has to fit the link that carries it', () {
    test('the send budget and the accept ceiling both fit the fragmenter', () {
      // A frame larger than the fragmenter can split is not slow, it is
      // undeliverable — fragmentFrame throws rather than truncating. On a
      // conservative 185-byte ATT MTU:
      const usable = kConservativeAttMtu - kAttHeaderBytes - kMtuSafetyMargin;
      const slice = usable - 1 - kFragHeaderLen;
      const maxFrame = kMaxFragments * slice;
      // Envelope + cipher tag + SealedBox + SignedPayload + tags, rounded up.
      const frameOverhead = 200;
      const maxJpeg = maxFrame - frameOverhead;

      expect(AvatarController.shareByteBudget, lessThan(maxJpeg),
          reason: 'what we send must be splittable');
      expect(AvatarPayload.maxBytes, lessThan(maxJpeg),
          reason: 'what we accept must be forwardable over BLE too');
      expect(AvatarController.shareByteBudget,
          lessThanOrEqualTo(AvatarPayload.maxBytes),
          reason: 'be strict in what you send, lenient in what you accept');
    });

    test('the size ladder starts at the largest circle we draw', () {
      // The contact profile hero is width * 0.48, ~173 pt on a 360 pt phone,
      // which is 518 physical pixels at 3x. Anything smaller upscales, which
      // is what made the big circle look chewed.
      expect(AvatarController.shareSizeLadder.first,
          AvatarController.shareSize);
      expect(AvatarController.shareSize, greaterThanOrEqualTo(512));
      // Descending, so the first entry that fits is also the best available.
      final ladder = AvatarController.shareSizeLadder;
      for (var i = 1; i < ladder.length; i++) {
        expect(ladder[i], lessThan(ladder[i - 1]));
      }
      final q = AvatarController.shareQualityLadder;
      for (var i = 1; i < q.length; i++) {
        expect(q[i], lessThan(q[i - 1]));
      }
    });
  });

  group('a picture is bound to the digest its owner signed', () {
    test('substituted bytes do not match the announced hash', () async {
      final real = Uint8List.fromList(List.generate(512, (i) => i & 0xFF));
      final swapped = Uint8List.fromList(List.generate(512, (i) => 255 - i));
      final announced = await _sha(real);

      // What PeerAvatarsController.store checks before caching anything: the
      // bytes arrive by one route, the digest by a signed one, and only bytes
      // that hash to it are kept. Anything able to deliver a frame could
      // otherwise choose what a contact's face looks like.
      expect(await _sha(real), equals(announced));
      expect(await _sha(swapped), isNot(equals(announced)));
    });
  });
}
