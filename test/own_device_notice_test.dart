import 'dart:convert';
import 'dart:typed_data';

import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:cubechat/core/transport/own_device_notice.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the devices of one account tell each other: "here I am", "sign that
/// one out", "I am leaving" (2026-10-12, docs/superpowers/specs/
/// 2026-10-12-own-devices-design.md).
void main() {
  Uint8List id(int seed) =>
      Uint8List.fromList(List.generate(16, (i) => (i * 7 + seed) & 0xff));
  const at = 1789000000123;

  test('takes the byte that was free for it', () {
    expect(InnerPayloadType.ownDevice.tag, 0xEB);
    expect(InnerPayloadType.fromByte(0xEB), InnerPayloadType.ownDevice);
  });

  test('a hello round-trips its name, platform and the answer flag', () {
    final back = OwnDeviceNotice.decode(
      OwnDeviceNotice.hello(
        deviceId: id(1),
        sentAtMs: at,
        name: 'Windows · ДОМАШНІЙ',
        platform: DevicePlatform.windows,
        answerRequested: true,
      ).encode(),
    );
    expect(back.kind, OwnDeviceKind.hello);
    expect(back.deviceId, equals(id(1)));
    expect(back.sentAtMs, at);
    expect(back.name, 'Windows · ДОМАШНІЙ');
    expect(back.platform, DevicePlatform.windows);
    expect(back.answerRequested, isTrue);
  });

  test('a sign-out names its target, a goodbye only its sender', () {
    final out = OwnDeviceNotice.decode(
      OwnDeviceNotice.signOut(deviceId: id(1), sentAtMs: at, targetId: id(2))
          .encode(),
    );
    expect(out.kind, OwnDeviceKind.signOut);
    expect(out.targetId, equals(id(2)));
    final bye = OwnDeviceNotice.decode(
      OwnDeviceNotice.goodbye(deviceId: id(3), sentAtMs: at).encode(),
    );
    expect(bye.kind, OwnDeviceKind.goodbye);
    expect(bye.deviceId, equals(id(3)));
  });

  test('a platform from a newer build reads as unknown, not as a failure', () {
    final bytes = OwnDeviceNotice.hello(
      deviceId: id(1),
      sentAtMs: at,
      name: 'x',
      platform: DevicePlatform.android,
    ).encode();
    bytes[1 + 1 + 8 + 16 + 1] = 0x7f; // the platform byte
    expect(OwnDeviceNotice.decode(bytes).platform, DevicePlatform.unknown);
  });

  test('bad input is refused, never trusted', () {
    final hello = OwnDeviceNotice.hello(
      deviceId: id(1),
      sentAtMs: at,
      name: 'phone',
      platform: DevicePlatform.ios,
    ).encode();
    Uint8List copy() => Uint8List.fromList(hello);

    final version = copy()..[0] = 0x02;
    expect(() => OwnDeviceNotice.decode(version), throwsFormatException);
    final kind = copy()..[1] = 0x09;
    expect(() => OwnDeviceNotice.decode(kind), throwsFormatException);
    expect(
      () => OwnDeviceNotice.decode(Uint8List.sublistView(hello, 0, 20)),
      throwsFormatException,
    );
    // A name length that runs past the end.
    final long = copy()..[1 + 1 + 8 + 16 + 2] = 200;
    expect(() => OwnDeviceNotice.decode(long), throwsFormatException);
    final signOut = OwnDeviceNotice.signOut(
      deviceId: id(1),
      sentAtMs: at,
      targetId: id(2),
    ).encode();
    expect(
      () => OwnDeviceNotice.decode(
        Uint8List.sublistView(signOut, 0, signOut.length - 1),
      ),
      throwsFormatException,
    );
  });

  group('profile parts', () {
    final hash = Uint8List.fromList(List.generate(32, (i) => 0xA0 ^ i));
    const len = OwnDeviceNotice.maxPartBytes + 10; // two parts

    OwnDeviceNotice part({
      int seq = 1,
      int total = 2,
      int avatarLen = len,
      Uint8List? avatarHash,
      Uint8List? bytes,
      String nickname = 'Даня 🐈',
    }) =>
        OwnDeviceNotice.profilePart(
          deviceId: id(4),
          sentAtMs: at,
          nickname: nickname,
          seq: seq,
          total: total,
          avatarLen: avatarLen,
          avatarHash: avatarHash ?? hash,
          part: bytes ?? Uint8List.fromList(List.filled(10, 0x5A)),
        );

    test('take the next free kind', () {
      expect(OwnDeviceKind.profile.tag, 0x04);
      expect(OwnDeviceKind.fromByte(0x04), OwnDeviceKind.profile);
    });

    test('round-trip the nickname, the count, the digest and the bytes', () {
      final back = OwnDeviceNotice.decode(part().encode());
      expect(back.kind, OwnDeviceKind.profile);
      expect(back.deviceId, equals(id(4)));
      expect(back.sentAtMs, at);
      expect(back.name, 'Даня 🐈');
      expect(back.seq, 1);
      expect(back.total, 2);
      expect(back.avatarLen, len);
      expect(back.avatarHash, equals(hash));
      expect(back.part, equals(List.filled(10, 0x5A)));
    });

    test('no picture is one empty part with an all-zero digest', () {
      final back = OwnDeviceNotice.decode(
        part(
          seq: 0,
          total: 1,
          avatarLen: 0,
          avatarHash: Uint8List(32),
          bytes: Uint8List(0),
        ).encode(),
      );
      expect(back.avatarLen, 0);
      expect(back.total, 1);
      expect(back.part, isEmpty);
      expect(OwnDeviceNotice.partsFor(0), 1);
      expect(OwnDeviceNotice.partsFor(1), 1);
      expect(OwnDeviceNotice.partsFor(OwnDeviceNotice.maxPartBytes), 1);
      expect(OwnDeviceNotice.partsFor(len), 2);
    });

    test('a part that cannot be one is refused on the way out', () {
      expect(() => part(seq: 2).encode(), throwsFormatException);
      expect(() => part(total: 3).encode(), throwsFormatException);
      expect(
        () => part(avatarHash: Uint8List(31)).encode(),
        throwsFormatException,
      );
      expect(
        () => part(
          seq: 0,
          total: 1,
          avatarLen: 0,
          bytes: Uint8List(1),
        ).encode(),
        throwsFormatException,
      );
      expect(
        () => part(
          bytes: Uint8List(OwnDeviceNotice.maxPartBytes + 1),
        ).encode(),
        throwsFormatException,
      );
      expect(
        () => part(
          avatarLen: OwnDeviceNotice.maxAvatarBytes + 1,
          total: OwnDeviceNotice.partsFor(OwnDeviceNotice.maxAvatarBytes + 1),
        ).encode(),
        throwsFormatException,
      );
    });

    test('tampered bytes are refused, never trusted', () {
      final good = part().encode();
      Uint8List copy() => Uint8List.fromList(good);
      const body = 1 + 1 + 8 + 16;
      final nickLen = good[body + 2];

      // seq past the count, and a count that does not fit the length.
      expect(
        () => OwnDeviceNotice.decode(copy()..[body] = 2),
        throwsFormatException,
      );
      expect(
        () => OwnDeviceNotice.decode(copy()..[body + 1] = 9),
        throwsFormatException,
      );
      // A nickname length that runs past the end, and one past the cap.
      expect(
        () => OwnDeviceNotice.decode(copy()..[body + 2] = 255),
        throwsFormatException,
      );
      // An avatar length past the cap.
      expect(
        () => OwnDeviceNotice.decode(copy()..[body + 3 + nickLen] = 0xFF),
        throwsFormatException,
      );
      // Cut inside the digest, and cut before the nickname.
      for (final end in [body + 3 + nickLen + 4 + 10, body + 2]) {
        expect(
          () => OwnDeviceNotice.decode(Uint8List.sublistView(good, 0, end)),
          throwsFormatException,
        );
      }
      // An empty "no picture" part that carries bytes after all.
      final none = part(
        seq: 0,
        total: 1,
        avatarLen: 0,
        avatarHash: Uint8List(32),
        bytes: Uint8List(0),
      ).encode();
      expect(
        () => OwnDeviceNotice.decode(
          Uint8List.fromList([...none, 0x01]),
        ),
        throwsFormatException,
      );
    });

    test('a nickname past 96 bytes is cut on a character', () {
      final back = OwnDeviceNotice.decode(part(nickname: 'Ж' * 60).encode());
      expect(utf8.encode(back.name!).length, lessThanOrEqualTo(96));
      expect(back.name, 'Ж' * 48);
    });
  });

  test('a name longer than 64 bytes is cut on a character, not mid-letter',
      () {
    final name = 'Ж' * 40; // 80 bytes
    final back = OwnDeviceNotice.decode(
      OwnDeviceNotice.hello(
        deviceId: id(1),
        sentAtMs: at,
        name: name,
        platform: DevicePlatform.android,
      ).encode(),
    );
    expect(utf8.encode(back.name!).length, lessThanOrEqualTo(64));
    expect(back.name, 'Ж' * 32);
  });
}
