import 'dart:async';
import 'dart:typed_data';

import 'package:cubechat/core/transport/own_device_notice.dart';
import 'package:cubechat/features/devices/data/own_profile_sync.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// One device of the account, as far as its profile goes: what it has, what
/// it sent and what it was told.
class _Device {
  _Device(this.id, {required this.relay, required DateTime Function() now}) {
    sync = OwnProfileSync(
      send: (n) async {
        if (offline) return false;
        sent.add(n);
        relay.add(n);
        return true;
      },
      inbound: relay.stream,
      deviceId: () async => id,
      current: () async => profile,
      apply: (p) async {
        applied.add(p);
        profile = p;
      },
      loadStamp: () async => stampOnDisk,
      saveStamp: (s) async => stampOnDisk = s,
      now: now,
    );
  }

  final Uint8List id;
  final StreamController<OwnDeviceNotice> relay;
  late final OwnProfileSync sync;
  OwnProfile profile = const OwnProfile(nickname: 'Anonymous');
  final List<OwnDeviceNotice> sent = [];
  final List<OwnProfile> applied = [];
  int stampOnDisk = 0;
  bool offline = false;

  /// The person changes the profile here, by hand.
  void edit(OwnProfile next) {
    profile = next;
    unawaited(sync.edited());
  }
}

/// The account's nickname and avatar between its devices: "поставил аву на
/// телефоне — на компе старая" (1152, 2026-10-15).
void main() {
  Uint8List id(int seed) =>
      Uint8List.fromList(List.generate(16, (i) => (i + seed) & 0xff));

  // Three parts' worth, every byte different enough to catch a misordering.
  final picture = Uint8List.fromList(
    List.generate(OwnDeviceNotice.maxPartBytes * 2 + 123, (i) => i * 31 & 0xff),
  );

  late StreamController<OwnDeviceNotice> relay;
  late DateTime clock;
  late _Device phone;
  late _Device laptop;

  // Built inside each test's fakeAsync, not in setUp: a future made outside
  // the fake zone completes in the real one, after the test has finished.
  void build() {
    relay = StreamController<OwnDeviceNotice>.broadcast(sync: true);
    clock = DateTime.utc(2026, 10, 15, 12);
    phone = _Device(id(1), relay: relay, now: () => clock);
    laptop = _Device(id(90), relay: relay, now: () => clock);
  }

  void startBoth(FakeAsync async, {OwnProfile? laptopHas}) {
    build();
    if (laptopHas != null) laptop.profile = laptopHas;
    unawaited(phone.sync.start());
    unawaited(laptop.sync.start());
    async.flushMicrotasks();
  }

  void settle(FakeAsync async) {
    async.elapse(const Duration(seconds: 30));
    async.flushMicrotasks();
  }

  test('a new picture and name set on the phone reach the computer', () {
    fakeAsync((async) {
      startBoth(async);
      phone.edit(OwnProfile(nickname: 'Даня', avatar: picture));
      settle(async);

      expect(phone.sent, hasLength(3));
      expect(phone.sent.map((n) => n.seq), [0, 1, 2]);
      expect(phone.sent.every((n) => n.kind == OwnDeviceKind.profile), isTrue);
      expect(laptop.applied, hasLength(1));
      expect(laptop.profile.nickname, 'Даня');
      expect(laptop.profile.avatar, equals(picture));
      expect(laptop.stampOnDisk, clock.millisecondsSinceEpoch);
      // Applied, not edited: the computer sends nothing back.
      expect(laptop.sent, isEmpty);
    });
  });

  test('a picture removed on one device is removed on the other', () {
    fakeAsync((async) {
      startBoth(
        async,
        laptopHas: OwnProfile(nickname: 'Даня', avatar: picture),
      );
      phone.edit(const OwnProfile(nickname: 'Даня'));
      settle(async);

      expect(phone.sent.single.avatarLen, 0);
      expect(laptop.profile.avatar, isNull);
    });
  });

  test('a name and a picture changed a moment apart go once', () {
    fakeAsync((async) {
      startBoth(async);
      phone.edit(OwnProfile(nickname: 'old', avatar: picture));
      async.elapse(const Duration(milliseconds: 500));
      phone.edit(OwnProfile(nickname: 'new', avatar: picture));
      settle(async);

      expect(phone.sent, hasLength(3));
      expect(laptop.applied.single.nickname, 'new');
    });
  });

  test('parts out of order still make the picture', () {
    fakeAsync((async) {
      build();
      final shuffled = StreamController<OwnDeviceNotice>.broadcast(sync: true);
      final laptopAlone = _Device(id(90), relay: shuffled, now: () => clock);
      final parts = <OwnDeviceNotice>[];
      final phoneAlone = _Device(
        id(1),
        relay: StreamController<OwnDeviceNotice>.broadcast(sync: true),
        now: () => clock,
      );
      phoneAlone.relay.stream.listen(parts.add);
      unawaited(phoneAlone.sync.start());
      unawaited(laptopAlone.sync.start());
      async.flushMicrotasks();
      phoneAlone.edit(OwnProfile(nickname: 'Даня', avatar: picture));
      settle(async);

      for (final n in parts.reversed) {
        shuffled.add(n);
      }
      settle(async);
      expect(laptopAlone.profile.avatar, equals(picture));
    });
  });

  test('bytes that do not match the digest are not applied', () {
    fakeAsync((async) {
      build();
      final tampering = StreamController<OwnDeviceNotice>.broadcast(sync: true);
      final victim = _Device(id(90), relay: tampering, now: () => clock);
      final parts = <OwnDeviceNotice>[];
      final source = _Device(
        id(1),
        relay: StreamController<OwnDeviceNotice>.broadcast(sync: true),
        now: () => clock,
      );
      source.relay.stream.listen(parts.add);
      unawaited(source.sync.start());
      unawaited(victim.sync.start());
      async.flushMicrotasks();
      source.edit(OwnProfile(nickname: 'Даня', avatar: picture));
      settle(async);

      final last = parts.last;
      final flipped = Uint8List.fromList(last.part!)..[0] ^= 0xff;
      for (final n in parts) {
        tampering.add(
          identical(n, last)
              ? OwnDeviceNotice.profilePart(
                  deviceId: n.deviceId,
                  sentAtMs: n.sentAtMs,
                  nickname: n.name!,
                  seq: n.seq,
                  total: n.total,
                  avatarLen: n.avatarLen,
                  avatarHash: n.avatarHash!,
                  part: flipped,
                )
              : n,
        );
      }
      settle(async);
      expect(victim.applied, isEmpty);
      expect(victim.stampOnDisk, 0);
    });
  });

  test('an older profile a relay hands over again changes nothing', () {
    fakeAsync((async) {
      startBoth(async);
      phone.edit(OwnProfile(nickname: 'first', avatar: picture));
      settle(async);
      final firstParts = List<OwnDeviceNotice>.of(phone.sent);

      clock = clock.add(const Duration(minutes: 5));
      phone.edit(const OwnProfile(nickname: 'second'));
      settle(async);
      expect(laptop.profile.nickname, 'second');

      for (final n in firstParts) {
        relay.add(n);
      }
      settle(async);
      expect(laptop.profile.nickname, 'second');
      expect(laptop.profile.avatar, isNull);
      expect(laptop.applied, hasLength(2));
    });
  });

  test('an edit here wins over an older one still on its way', () {
    fakeAsync((async) {
      startBoth(async);
      final earlier = clock.millisecondsSinceEpoch;
      clock = clock.add(const Duration(minutes: 1));
      laptop.edit(const OwnProfile(nickname: 'laptop'));
      // The phone's change, made before the laptop's, lands after it.
      relay.add(
        OwnDeviceNotice.profilePart(
          deviceId: phone.id,
          sentAtMs: earlier,
          nickname: 'phone',
          seq: 0,
          total: 1,
          avatarLen: 0,
          avatarHash: Uint8List(32),
          part: Uint8List(0),
        ),
      );
      settle(async);
      expect(laptop.profile.nickname, 'laptop');
      expect(laptop.applied, isEmpty);
    });
  });

  test('a clock behind still produces a change the others take', () {
    fakeAsync((async) {
      startBoth(async);
      phone.edit(const OwnProfile(nickname: 'phone'));
      settle(async);
      // The laptop's clock is an hour behind the phone's.
      final laptopBehind = _Device(
        id(90),
        relay: relay,
        now: () => clock.subtract(const Duration(hours: 1)),
      )..stampOnDisk = laptop.stampOnDisk;
      laptop.sync.dispose();
      unawaited(laptopBehind.sync.start());
      async.flushMicrotasks();
      laptopBehind.edit(const OwnProfile(nickname: 'laptop'));
      settle(async);
      expect(
        laptopBehind.sent.single.sentAtMs,
        greaterThan(clock.millisecondsSinceEpoch),
      );
      expect(phone.profile.nickname, 'laptop');
    });
  });

  test('a part that never leaves stops the profile, after retries', () {
    fakeAsync((async) {
      startBoth(async);
      phone.offline = true;
      phone.edit(OwnProfile(nickname: 'Даня', avatar: picture));
      settle(async);
      expect(laptop.applied, isEmpty);
    });
  });

  test('hello, sign-out and goodbye are not a profile', () {
    fakeAsync((async) {
      startBoth(async);
      relay.add(
        OwnDeviceNotice.goodbye(
          deviceId: phone.id,
          sentAtMs: clock.millisecondsSinceEpoch,
        ),
      );
      settle(async);
      expect(laptop.applied, isEmpty);
    });
  });
}
