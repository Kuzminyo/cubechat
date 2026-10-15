import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:flutter/foundation.dart';

import '../../../core/transport/own_device_notice.dart';
import '../../../core/util/debug_log.dart';
import 'device_identity.dart';

/// The account's own nickname and avatar, as one device has them.
@immutable
class OwnProfile {
  const OwnProfile({required this.nickname, this.avatar});

  final String nickname;

  /// The stored picture, byte for byte, or null for none.
  final Uint8List? avatar;
}

/// Keeps the account's nickname and avatar the same on all of its devices.
///
/// Before this the only copy was the one made when a computer signed in from
/// the phone, so a new picture set on the phone never reached the computer:
/// "поставил аву на телефоне — на компе старая" (1152, 2026-10-15).
///
/// A change made **by hand** on this device ([edited]) is sent to the others
/// as [OwnDeviceKind.profile] parts, the avatar's stored bytes in order, all
/// stamped with the moment of the change. A device applies a profile only
/// once every part is in and the bytes match the digest, and only when its
/// moment is later than the profile it already has — last writer wins. Only
/// notices `MessagingService.signedByOwnKey` accepted reach [inbound].
///
/// A profile applied from another device is not an edit and is never sent on,
/// which is what keeps two devices from answering each other forever. Neither
/// is a restore, a wipe or a read from disk.
///
/// The stored bytes travel, not the smaller copy contacts get, so both devices
/// hold the same picture and derive the same copy and the same digest from it
/// — contacts then see one face for the account, not whichever device spoke
/// last. A desktop sign-in copies the same bytes for the same reason.
class OwnProfileSync {
  OwnProfileSync({
    required this.send,
    required Stream<OwnDeviceNotice> inbound,
    required this.deviceId,
    required this.current,
    required this.apply,
    required this.loadStamp,
    required this.saveStamp,
    DateTime Function()? now,
  })  : _inbound = inbound,
        _now = now ?? DateTime.now;

  /// Hand one part to the relay; true when it left this device.
  final Future<bool> Function(OwnDeviceNotice notice) send;
  final Stream<OwnDeviceNotice> _inbound;
  final Future<Uint8List> Function() deviceId;
  final Future<OwnProfile> Function() current;
  final Future<void> Function(OwnProfile profile) apply;

  /// The moment of the profile this device has, kept across launches. In the
  /// settings box, so a desktop sign-in inherits the phone's along with the
  /// picture and the name it belongs to.
  final Future<int> Function() loadStamp;
  final Future<void> Function(int stamp) saveStamp;
  final DateTime Function() _now;

  /// Wait after an edit before sending, so a new picture and a new name set a
  /// moment apart go once, together.
  static const Duration publishDelay = Duration(seconds: 2);

  /// Between two parts. The media lane takes a burst — a circle is one — but
  /// public relays answer one with "rate-limited", and a part lost is a
  /// profile that never completes on the other side.
  static const Duration partGap = Duration(milliseconds: 150);

  /// Tries per part before the profile is given up on until the next edit.
  static const int sendAttempts = 3;
  static const Duration retryBackoff = Duration(milliseconds: 800);

  /// Profiles being put together at once. Two edits made while a device was
  /// off arrive together; more than that is somebody filling memory.
  static const int maxAssemblies = 3;

  Uint8List? _myId;
  int _stamp = 0;
  final Map<String, _Assembly> _assembling = {};
  StreamSubscription<OwnDeviceNotice>? _subscription;
  Timer? _publishTimer;
  bool _sending = false;
  bool _sendAgain = false;
  bool _disposed = false;
  Future<void> _applying = Future<void>.value();
  Future<void>? _starting;

  /// The moment of the profile this device has now.
  int get stamp => _stamp;

  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    _myId = await deviceId();
    _stamp = await loadStamp();
    if (_disposed) return;
    _subscription = _inbound.listen(_receive);
  }

  /// The person changed their nickname or avatar on this device.
  ///
  /// The moment is taken now, not when the parts go: a profile from another
  /// device landing in between must not overwrite the change it is older
  /// than. Never earlier than the profile already held, so a clock behind
  /// another device's still produces a change the others take.
  Future<void> edited() async {
    await start();
    if (_disposed) return;
    final now = _now().millisecondsSinceEpoch;
    _stamp = now > _stamp ? now : _stamp + 1;
    await saveStamp(_stamp);
    _assembling.removeWhere((_, a) => a.sentAtMs <= _stamp);
    _publishTimer?.cancel();
    _publishTimer = Timer(publishDelay, () => unawaited(_publish()));
  }

  Future<void> _publish() async {
    if (_sending) {
      _sendAgain = true;
      return;
    }
    _sending = true;
    try {
      do {
        _sendAgain = false;
        await _sendProfile(_stamp);
      } while (_sendAgain && !_disposed);
    } finally {
      _sending = false;
    }
  }

  Future<void> _sendProfile(int at) async {
    final id = _myId;
    if (id == null || _disposed) return;
    final profile = await current();
    final avatar = profile.avatar ?? Uint8List(0);
    if (avatar.length > OwnDeviceNotice.maxAvatarBytes) {
      // Sending the name alone would read as "no picture" and clear the
      // others' — better that they keep the old one.
      DebugLog.instance.log(
        'DEVICES',
        'profile not sent: avatar ${avatar.length}B is past the cap',
      );
      return;
    }
    final hash = avatar.isEmpty
        ? Uint8List(OwnDeviceNotice.hashLen)
        : Uint8List.fromList((await Sha256().hash(avatar)).bytes);
    final total = OwnDeviceNotice.partsFor(avatar.length);
    for (var seq = 0; seq < total; seq++) {
      // A later edit supersedes this one; its own send carries everything.
      if (_disposed || _stamp != at) return;
      final start = seq * OwnDeviceNotice.maxPartBytes;
      final end = (start + OwnDeviceNotice.maxPartBytes).clamp(0, avatar.length);
      final notice = OwnDeviceNotice.profilePart(
        deviceId: id,
        sentAtMs: at,
        nickname: profile.nickname,
        seq: seq,
        total: total,
        avatarLen: avatar.length,
        avatarHash: hash,
        part: Uint8List.sublistView(avatar, start, end),
      );
      var sent = false;
      for (var attempt = 1; attempt <= sendAttempts && !sent; attempt++) {
        try {
          sent = await send(notice);
        } catch (e) {
          DebugLog.instance.log('DEVICES', 'profile part failed: $e');
        }
        if (!sent && attempt < sendAttempts) {
          await Future<void>.delayed(retryBackoff * attempt);
        }
      }
      if (!sent) {
        DebugLog.instance.log(
          'DEVICES',
          'profile not sent: part ${seq + 1}/$total did not leave',
        );
        return;
      }
      if (seq + 1 < total) await Future<void>.delayed(partGap);
    }
    DebugLog.instance.log(
      'DEVICES',
      'profile sent: ${avatar.length}B in $total part(s)',
    );
  }

  void _receive(OwnDeviceNotice notice) {
    if (notice.kind != OwnDeviceKind.profile) return;
    final myId = _myId;
    if (myId == null) return;
    final from = deviceIdHex(notice.deviceId);
    if (from == deviceIdHex(myId)) return; // our own, back from a relay
    // Not newer than what this device has: an old event a relay handed over
    // again, or a change this device has already overtaken.
    if (notice.sentAtMs <= _stamp) return;
    final key = '$from:${notice.sentAtMs}';
    final assembly = _assembling.putIfAbsent(key, () => _Assembly(notice));
    if (!assembly.fits(notice)) {
      DebugLog.instance.log(
        'DEVICES',
        'drop profile from ${from.substring(0, 8)}: parts disagree',
      );
      _assembling.remove(key);
      return;
    }
    assembly.parts[notice.seq] = notice.part;
    while (_assembling.length > maxAssemblies) {
      final oldest = _assembling.entries
          .reduce((a, b) => a.value.sentAtMs <= b.value.sentAtMs ? a : b);
      _assembling.remove(oldest.key);
    }
    if (!assembly.complete) return;
    _assembling.remove(key);
    // One at a time, so two profiles finishing together are applied in the
    // order their moments say, not in the order their digests came back.
    _applying = _applying.then((_) => _finish(assembly, from));
  }

  Future<void> _finish(_Assembly assembly, String from) async {
    try {
      final bytes = assembly.join();
      if (bytes.length != assembly.avatarLen) {
        DebugLog.instance.log('DEVICES', 'drop profile: wrong length');
        return;
      }
      if (bytes.isNotEmpty) {
        final digest = (await Sha256().hash(bytes)).bytes;
        if (!listEquals(digest, assembly.hash)) {
          DebugLog.instance.log('DEVICES', 'drop profile: digest mismatch');
          return;
        }
      }
      if (_disposed || assembly.sentAtMs <= _stamp) return;
      _stamp = assembly.sentAtMs;
      await saveStamp(_stamp);
      _assembling.removeWhere((_, a) => a.sentAtMs <= _stamp);
      await apply(
        OwnProfile(
          nickname: assembly.nickname,
          avatar: bytes.isEmpty ? null : bytes,
        ),
      );
      DebugLog.instance.log(
        'DEVICES',
        'profile from ${from.substring(0, 8)}: ${bytes.length}B avatar',
      );
    } catch (e) {
      DebugLog.instance.log('DEVICES', 'applying a profile failed: $e');
    }
  }

  void dispose() {
    _disposed = true;
    _publishTimer?.cancel();
    unawaited(_subscription?.cancel());
  }
}

/// The parts of one profile from one device, as they come in.
class _Assembly {
  _Assembly(OwnDeviceNotice first)
      : sentAtMs = first.sentAtMs,
        nickname = first.name ?? '',
        avatarLen = first.avatarLen,
        hash = first.avatarHash!,
        parts = List<Uint8List?>.filled(first.total, null);

  final int sentAtMs;
  final String nickname;
  final int avatarLen;
  final Uint8List hash;
  final List<Uint8List?> parts;

  /// Whether [n] is a part of this profile and not of some other one claiming
  /// the same moment.
  bool fits(OwnDeviceNotice n) =>
      n.total == parts.length &&
      n.avatarLen == avatarLen &&
      (n.name ?? '') == nickname &&
      listEquals(n.avatarHash, hash);

  bool get complete => parts.every((p) => p != null);

  Uint8List join() {
    final out = BytesBuilder(copy: false);
    for (final p in parts) {
      out.add(p!);
    }
    return out.takeBytes();
  }
}
