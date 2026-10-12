import 'dart:convert';
import 'dart:typed_data';

/// What one device of an account tells the others, sealed to the key they
/// share — [InnerPayloadType.ownDevice] (0xEB).
///
/// ```
///   [version:1 = 0x01][kind:1][sentAtMs:8][deviceId:16][body]
///   hello    body = [flags:1][platform:1][nameLen:1][name:nameLen]
///   signOut  body = [targetId:16]
///   goodbye  body = —
/// ```
///
/// The moment travels inside, as an invite's does: relays hand stored events
/// over again on every reconnect, and only this says how old one is.
enum OwnDeviceKind {
  /// "Here I am", with a name and a platform. Flag bit 0 asks the others to
  /// answer with their own hello, so a new device learns the list at once.
  hello(0x01),

  /// "Sign the device [OwnDeviceNotice.targetId] out."
  signOut(0x02),

  /// "I am leaving" — signed out or wiped; take me off the list.
  goodbye(0x03);

  const OwnDeviceKind(this.tag);
  final int tag;

  static OwnDeviceKind fromByte(int b) {
    for (final v in OwnDeviceKind.values) {
      if (v.tag == b) return v;
    }
    throw FormatException('unknown own-device kind 0x${b.toRadixString(16)}');
  }
}

enum DevicePlatform {
  unknown(0),
  android(1),
  ios(2),
  windows(3),
  macos(4),
  linux(5);

  const DevicePlatform(this.tag);
  final int tag;

  /// A platform added by a newer build reads as unknown: the list shows the
  /// device without an icon rather than not at all.
  static DevicePlatform fromByte(int b) {
    for (final v in DevicePlatform.values) {
      if (v.tag == b) return v;
    }
    return DevicePlatform.unknown;
  }
}

class OwnDeviceNotice {
  const OwnDeviceNotice._({
    required this.kind,
    required this.deviceId,
    required this.sentAtMs,
    this.name,
    this.platform = DevicePlatform.unknown,
    this.answerRequested = false,
    this.targetId,
  });

  factory OwnDeviceNotice.hello({
    required Uint8List deviceId,
    required int sentAtMs,
    required String name,
    required DevicePlatform platform,
    bool answerRequested = false,
  }) =>
      OwnDeviceNotice._(
        kind: OwnDeviceKind.hello,
        deviceId: deviceId,
        sentAtMs: sentAtMs,
        name: name,
        platform: platform,
        answerRequested: answerRequested,
      );

  factory OwnDeviceNotice.signOut({
    required Uint8List deviceId,
    required int sentAtMs,
    required Uint8List targetId,
  }) =>
      OwnDeviceNotice._(
        kind: OwnDeviceKind.signOut,
        deviceId: deviceId,
        sentAtMs: sentAtMs,
        targetId: targetId,
      );

  factory OwnDeviceNotice.goodbye({
    required Uint8List deviceId,
    required int sentAtMs,
  }) =>
      OwnDeviceNotice._(
        kind: OwnDeviceKind.goodbye,
        deviceId: deviceId,
        sentAtMs: sentAtMs,
      );

  static const int version = 0x01;
  static const int idLen = 16;

  /// A device's name on the wire, at most. Longer is cut on a character.
  static const int maxNameBytes = 64;
  static const int _headerLen = 2 + 8 + idLen;

  final OwnDeviceKind kind;
  final Uint8List deviceId;
  final int sentAtMs;
  final String? name;
  final DevicePlatform platform;
  final bool answerRequested;
  final Uint8List? targetId;

  Uint8List encode() {
    if (deviceId.length != idLen) {
      throw const FormatException('a device id is 16 bytes');
    }
    final body = BytesBuilder(copy: false);
    switch (kind) {
      case OwnDeviceKind.hello:
        final nameBytes = _cut(name ?? '');
        body
          ..addByte(answerRequested ? 0x01 : 0x00)
          ..addByte(platform.tag)
          ..addByte(nameBytes.length)
          ..add(nameBytes);
      case OwnDeviceKind.signOut:
        final target = targetId!;
        if (target.length != idLen) {
          throw const FormatException('a target id is 16 bytes');
        }
        body.add(target);
      case OwnDeviceKind.goodbye:
        break;
    }
    final head = Uint8List(_headerLen);
    head[0] = version;
    head[1] = kind.tag;
    // Cut in two arithmetically, as the call invite's is: on the web an int
    // is a double and a 32-bit shift loses the top of the number.
    final view = ByteData.sublistView(head);
    view.setUint32(2, sentAtMs ~/ 0x100000000);
    view.setUint32(6, sentAtMs % 0x100000000);
    head.setRange(10, _headerLen, deviceId);
    return (BytesBuilder(copy: false)
          ..add(head)
          ..add(body.takeBytes()))
        .takeBytes();
  }

  static OwnDeviceNotice decode(Uint8List bytes) {
    if (bytes.length < _headerLen) {
      throw const FormatException('own-device notice truncated');
    }
    if (bytes[0] != version) {
      throw FormatException('unknown own-device version ${bytes[0]}');
    }
    final kind = OwnDeviceKind.fromByte(bytes[1]);
    final view = ByteData.sublistView(bytes);
    final sentAtMs = view.getUint32(2) * 0x100000000 + view.getUint32(6);
    final deviceId = Uint8List.fromList(bytes.sublist(10, _headerLen));
    final body = Uint8List.sublistView(bytes, _headerLen);
    switch (kind) {
      case OwnDeviceKind.hello:
        if (body.length < 3) {
          throw const FormatException('a hello is truncated');
        }
        final nameLen = body[2];
        if (nameLen > maxNameBytes || body.length < 3 + nameLen) {
          throw const FormatException('a hello name runs past its end');
        }
        return OwnDeviceNotice.hello(
          deviceId: deviceId,
          sentAtMs: sentAtMs,
          answerRequested: body[0] & 0x01 != 0,
          platform: DevicePlatform.fromByte(body[1]),
          name: utf8.decode(body.sublist(3, 3 + nameLen), allowMalformed: true),
        );
      case OwnDeviceKind.signOut:
        if (body.length < idLen) {
          throw const FormatException('a sign-out names no device');
        }
        return OwnDeviceNotice.signOut(
          deviceId: deviceId,
          sentAtMs: sentAtMs,
          targetId: Uint8List.fromList(body.sublist(0, idLen)),
        );
      case OwnDeviceKind.goodbye:
        return OwnDeviceNotice.goodbye(deviceId: deviceId, sentAtMs: sentAtMs);
    }
  }

  /// [text] as UTF-8, no longer than [maxNameBytes], cut between characters.
  static Uint8List _cut(String text) {
    var out = utf8.encode(text);
    if (out.length <= maxNameBytes) return Uint8List.fromList(out);
    final runes = text.runes.toList();
    while (out.length > maxNameBytes && runes.isNotEmpty) {
      runes.removeLast();
      out = utf8.encode(String.fromCharCodes(runes));
    }
    return Uint8List.fromList(out);
  }
}
