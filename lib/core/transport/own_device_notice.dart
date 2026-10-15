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
///   profile  body = [seq:1][total:1][nickLen:1][nick:nickLen]
///                   [avatarLen:4][avatarSha256:32][part]
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
  goodbye(0x03),

  /// One part of the account's own profile — nickname and avatar — as the
  /// sending device has had it since [OwnDeviceNotice.sentAtMs]. Every part
  /// of one profile carries the same moment, nickname, length and digest; the
  /// parts carry the avatar's bytes in order, [OwnDeviceNotice.maxPartBytes]
  /// at most each. No avatar is one part with a length of zero.
  ///
  /// Added after 1152. A 1147–1152 build has no such kind: its decoder throws
  /// a FormatException on the kind byte and the receive branch drops the
  /// notice with a log line. Hello, sign-out and goodbye are notices of their
  /// own, so nothing they do changes.
  profile(0x04);

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
    this.seq = 0,
    this.total = 0,
    this.avatarLen = 0,
    this.avatarHash,
    this.part,
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

  /// One part of a profile — see [OwnDeviceKind.profile].
  ///
  /// The nickname is whole in every part, so whichever part arrives first
  /// already says which profile it belongs to. [avatarHash] is the SHA-256 of
  /// all [avatarLen] bytes, all-zero when there is no picture.
  factory OwnDeviceNotice.profilePart({
    required Uint8List deviceId,
    required int sentAtMs,
    required String nickname,
    required int seq,
    required int total,
    required int avatarLen,
    required Uint8List avatarHash,
    required Uint8List part,
  }) =>
      OwnDeviceNotice._(
        kind: OwnDeviceKind.profile,
        deviceId: deviceId,
        sentAtMs: sentAtMs,
        name: nickname,
        seq: seq,
        total: total,
        avatarLen: avatarLen,
        avatarHash: avatarHash,
        part: part,
      );

  static const int version = 0x01;
  static const int idLen = 16;

  /// A device's name on the wire, at most. Longer is cut on a character.
  static const int maxNameBytes = 64;
  static const int _headerLen = 2 + 8 + idLen;

  /// A nickname on the wire, at most. `NicknameController.maxLength` is 24
  /// characters, and 24 four-byte characters are 96 bytes.
  static const int maxNicknameBytes = 96;

  /// Avatar bytes in one profile part. Parts go to the relay alone — the
  /// devices of one account are wherever the internet is, never a Bluetooth
  /// neighbour — so they are sized for one event: base64 makes 32 KiB about
  /// 44 KB, a third of the 131072 the relays of the media lane accept
  /// (`kRelayMediaChunkData` goes to 63 KiB on the same relays).
  static const int maxPartBytes = 32 * 1024;

  /// The largest avatar a profile carries. The stored picture is a 1920 px
  /// JPEG at quality 90 (`AvatarController.storedSize`), a megabyte or so for
  /// a busy photo; four is room for that and a bound on what a stream of parts
  /// can make the other device hold.
  static const int maxAvatarBytes = 4 * 1024 * 1024;

  static const int hashLen = 32;

  final OwnDeviceKind kind;
  final Uint8List deviceId;
  final int sentAtMs;
  final String? name;
  final DevicePlatform platform;
  final bool answerRequested;
  final Uint8List? targetId;

  /// Profile only: which part this is, of how many.
  final int seq;
  final int total;

  /// Profile only: the whole avatar's length and SHA-256, and this part of it.
  final int avatarLen;
  final Uint8List? avatarHash;
  final Uint8List? part;

  Uint8List encode() {
    if (deviceId.length != idLen) {
      throw const FormatException('a device id is 16 bytes');
    }
    final body = BytesBuilder(copy: false);
    switch (kind) {
      case OwnDeviceKind.hello:
        final nameBytes = _cut(name ?? '', maxNameBytes);
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
      case OwnDeviceKind.profile:
        final hash = avatarHash!;
        final bytes = part!;
        _checkProfile(seq, total, avatarLen, hash, bytes);
        final nick = _cut(name ?? '', maxNicknameBytes);
        final len = ByteData(4)..setUint32(0, avatarLen);
        body
          ..addByte(seq)
          ..addByte(total)
          ..addByte(nick.length)
          ..add(nick)
          ..add(len.buffer.asUint8List())
          ..add(hash)
          ..add(bytes);
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
      case OwnDeviceKind.profile:
        if (body.length < 3) {
          throw const FormatException('a profile part is truncated');
        }
        final nickLen = body[2];
        final lenAt = 3 + nickLen;
        final hashAt = lenAt + 4;
        final partAt = hashAt + hashLen;
        if (nickLen > maxNicknameBytes || body.length < partAt) {
          throw const FormatException('a profile part runs past its end');
        }
        final seq = body[0];
        final total = body[1];
        final avatarLen =
            ByteData.sublistView(body, lenAt, hashAt).getUint32(0);
        final hash = Uint8List.fromList(body.sublist(hashAt, partAt));
        final part = Uint8List.fromList(body.sublist(partAt));
        _checkProfile(seq, total, avatarLen, hash, part);
        return OwnDeviceNotice.profilePart(
          deviceId: deviceId,
          sentAtMs: sentAtMs,
          nickname: utf8.decode(body.sublist(3, lenAt), allowMalformed: true),
          seq: seq,
          total: total,
          avatarLen: avatarLen,
          avatarHash: hash,
          part: part,
        );
    }
  }

  /// Parts needed for an avatar of [avatarLen] bytes — one for none.
  static int partsFor(int avatarLen) => avatarLen == 0
      ? 1
      : (avatarLen + maxPartBytes - 1) ~/ maxPartBytes;

  /// What every profile part must be, on the way out and on the way in: a
  /// part inside a count that fits the length, no part larger than
  /// [maxPartBytes], and "no picture" as exactly one empty part. Checked on
  /// encode too, so a bad part fails here rather than on every other device.
  static void _checkProfile(
    int seq,
    int total,
    int avatarLen,
    Uint8List hash,
    Uint8List part,
  ) {
    if (hash.length != hashLen) {
      throw const FormatException('an avatar digest is 32 bytes');
    }
    if (avatarLen > maxAvatarBytes) {
      throw const FormatException('a profile avatar past the cap');
    }
    if (total != partsFor(avatarLen) || seq < 0 || seq >= total) {
      throw const FormatException('a profile part outside its count');
    }
    if (part.length > maxPartBytes) {
      throw const FormatException('a profile part past the cap');
    }
    if (avatarLen == 0 && part.isNotEmpty) {
      throw const FormatException('no picture is one empty part');
    }
  }

  /// [text] as UTF-8, no longer than [max] bytes, cut between characters.
  static Uint8List _cut(String text, int max) {
    var out = utf8.encode(text);
    if (out.length <= max) return Uint8List.fromList(out);
    final runes = text.runes.toList();
    while (out.length > max && runes.isNotEmpty) {
      runes.removeLast();
      out = utf8.encode(String.fromCharCodes(runes));
    }
    return Uint8List.fromList(out);
  }
}
