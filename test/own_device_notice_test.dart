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
