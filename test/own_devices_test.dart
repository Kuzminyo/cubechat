import 'dart:async';
import 'dart:typed_data';

import 'package:cubechat/core/transport/own_device_notice.dart';
import 'package:cubechat/features/devices/data/device_identity.dart';
import 'package:cubechat/features/devices/data/own_devices.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

class _Store implements DeviceIdentityStore {
  _Store(this._id);
  final Uint8List _id;
  String? stored;
  bool wiped = false;
  @override
  Future<Uint8List> id() async => _id;
  @override
  Future<String?> name() async => stored;
  @override
  Future<void> setName(String name) async => stored = name;
  @override
  Future<void> wipe() async => wiped = true;
}

/// The list of an account's devices and signing one out (2026-10-12,
/// docs/superpowers/specs/2026-10-12-own-devices-design.md).
void main() {
  Uint8List id(int seed) =>
      Uint8List.fromList(List.generate(16, (i) => (i + seed) & 0xff));
  final me = id(1);
  final phone = id(50);
  final laptop = id(90);

  late List<OwnDeviceNotice> sent;
  late StreamController<OwnDeviceNotice> inbound;
  late List<OwnDevice>? saved;
  late List<OwnDevice> onDisk;
  late DateTime clock;
  late _Store store;

  OwnDevicesService build() => OwnDevicesService(
        send: (n) async => sent.add(n),
        inbound: inbound.stream,
        store: store,
        load: () async => onDisk,
        save: (list) async => saved = list,
        platform: DevicePlatform.windows,
        defaultName: 'Windows · DESK',
        now: () => clock,
      );

  setUp(() {
    sent = [];
    inbound = StreamController<OwnDeviceNotice>.broadcast(sync: true);
    saved = null;
    onDisk = [];
    clock = DateTime.utc(2026, 10, 12, 12);
    store = _Store(me);
  });

  OwnDeviceNotice hello(
    Uint8List from, {
    String name = 'Pixel',
    bool answer = false,
    DateTime? at,
  }) =>
      OwnDeviceNotice.hello(
        deviceId: from,
        sentAtMs: (at ?? clock).millisecondsSinceEpoch,
        name: name,
        platform: DevicePlatform.android,
        answerRequested: answer,
      );

  test('starting says hello and asks the others to answer', () {
    fakeAsync((async) {
      final devices = build();
      unawaited(devices.start());
      async.flushMicrotasks();
      expect(sent.single.kind, OwnDeviceKind.hello);
      expect(sent.single.answerRequested, isTrue);
      expect(sent.single.deviceId, equals(me));
      expect(sent.single.name, 'Windows · DESK');
      expect(sent.single.platform, DevicePlatform.windows);
      devices.dispose();
    });
  });

  test('a new device is answered once, without asking back', () {
    fakeAsync((async) {
      final devices = build();
      unawaited(devices.start());
      async.flushMicrotasks();
      sent.clear();
      inbound.add(hello(phone, answer: true));
      async.flushMicrotasks();
      expect(sent.single.kind, OwnDeviceKind.hello);
      expect(sent.single.answerRequested, isFalse,
          reason: 'two devices asking each other would never stop');
      expect(devices.others.single.idHex, deviceIdHex(phone));
      expect(devices.others.single.name, 'Pixel');
      sent.clear();
      inbound.add(hello(phone));
      async.flushMicrotasks();
      expect(sent, isEmpty, reason: 'a hello that asks nothing gets nothing');
      devices.dispose();
    });
  });

  test('an old hello a relay replays does not move "last seen" back', () {
    fakeAsync((async) {
      final devices = build();
      unawaited(devices.start());
      async.flushMicrotasks();
      inbound.add(hello(phone, at: clock));
      inbound.add(hello(phone, name: 'Old', at: clock.subtract(
        const Duration(days: 3),
      )));
      async.flushMicrotasks();
      expect(devices.others.single.lastSeen, clock);
      expect(devices.others.single.name, 'Pixel',
          reason: 'the newer word on its name stands');
      expect(saved, isNotNull, reason: 'the list is kept');
      devices.dispose();
    });
  });

  test('our own hello coming back is not another device', () {
    fakeAsync((async) {
      final devices = build();
      unawaited(devices.start());
      async.flushMicrotasks();
      inbound.add(hello(me));
      async.flushMicrotasks();
      expect(devices.others, isEmpty);
      devices.dispose();
    });
  });

  test('a profile part is not a device saying hello', () {
    fakeAsync((async) {
      final devices = build();
      unawaited(devices.start());
      async.flushMicrotasks();
      sent.clear();
      inbound.add(
        OwnDeviceNotice.profilePart(
          deviceId: phone,
          sentAtMs: clock.millisecondsSinceEpoch,
          nickname: 'Pixel',
          seq: 0,
          total: 1,
          avatarLen: 0,
          avatarHash: Uint8List(32),
          part: Uint8List(0),
        ),
      );
      async.flushMicrotasks();
      expect(devices.others, isEmpty);
      expect(sent, isEmpty);
      devices.dispose();
    });
  });

  test('a sign-out for another device marks it, and does not touch this one',
      () {
    fakeAsync((async) {
      var out = false;
      final devices = build();
      devices.signedOutHere.listen((_) => out = true);
      unawaited(devices.start());
      async.flushMicrotasks();
      inbound.add(hello(phone));
      inbound.add(OwnDeviceNotice.signOut(
        deviceId: laptop,
        sentAtMs: clock.millisecondsSinceEpoch,
        targetId: phone,
      ));
      async.flushMicrotasks();
      expect(out, isFalse);
      expect(devices.others.single.leaving, isTrue);
      devices.dispose();
    });
  });

  test('a sign-out for this device says goodbye and signs out here', () {
    fakeAsync((async) {
      var out = false;
      final devices = build();
      devices.signedOutHere.listen((_) => out = true);
      unawaited(devices.start());
      async.flushMicrotasks();
      sent.clear();
      inbound.add(OwnDeviceNotice.signOut(
        deviceId: phone,
        sentAtMs: clock.millisecondsSinceEpoch,
        targetId: me,
      ));
      async.flushMicrotasks();
      expect(sent.single.kind, OwnDeviceKind.goodbye);
      expect(out, isTrue);
      devices.dispose();
    });
  });

  test('a goodbye takes the device off the list', () {
    fakeAsync((async) {
      final devices = build();
      unawaited(devices.start());
      async.flushMicrotasks();
      inbound.add(hello(phone));
      inbound.add(OwnDeviceNotice.goodbye(
        deviceId: phone,
        sentAtMs: clock.millisecondsSinceEpoch,
      ));
      async.flushMicrotasks();
      expect(devices.others, isEmpty);
      devices.dispose();
    });
  });

  test('signing one out sends its id; signing out all sends every id', () {
    fakeAsync((async) {
      final devices = build();
      unawaited(devices.start());
      async.flushMicrotasks();
      inbound.add(hello(phone));
      inbound.add(hello(laptop, name: 'Laptop'));
      async.flushMicrotasks();
      sent.clear();
      unawaited(devices.signOut(deviceIdHex(phone)));
      async.flushMicrotasks();
      expect(sent.single.kind, OwnDeviceKind.signOut);
      expect(sent.single.targetId, equals(phone));
      expect(
        devices.others.firstWhere((d) => d.idHex == deviceIdHex(phone)).leaving,
        isTrue,
      );
      sent.clear();
      unawaited(devices.signOutOthers());
      async.flushMicrotasks();
      expect(
        sent.map((n) => deviceIdHex(n.targetId!)).toSet(),
        {deviceIdHex(phone), deviceIdHex(laptop)},
      );
      devices.dispose();
    });
  });

  test('renaming keeps the name here and tells the others', () {
    fakeAsync((async) {
      final devices = build();
      unawaited(devices.start());
      async.flushMicrotasks();
      sent.clear();
      unawaited(devices.rename('Робочий ПК'));
      async.flushMicrotasks();
      expect(store.stored, 'Робочий ПК');
      expect(devices.myName, 'Робочий ПК');
      expect(sent.single.name, 'Робочий ПК');
      devices.dispose();
    });
  });

  test('hello again every six hours, and quiet devices are forgotten', () {
    fakeAsync((async) {
      onDisk = [
        OwnDevice(
          idHex: deviceIdHex(laptop),
          name: 'Laptop',
          platform: DevicePlatform.windows,
          lastSeen: clock.subtract(const Duration(days: 61)),
        ),
      ];
      final devices = build();
      unawaited(devices.start());
      async.flushMicrotasks();
      expect(devices.others, isEmpty,
          reason: 'silent for two months: gone, or never coming back');
      sent.clear();
      async.elapse(OwnDevicesService.helloEvery);
      expect(sent.single.kind, OwnDeviceKind.hello);
      expect(sent.single.answerRequested, isFalse);
      devices.dispose();
    });
  });
}
