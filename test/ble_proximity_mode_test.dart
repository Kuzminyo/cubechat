import 'dart:async';

import 'package:cubechat/core/ble/ble_constants.dart';
import 'package:cubechat/core/ble/ble_scanner.dart';
import 'package:cubechat/features/peers/models/discovered_peer.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

/// One advertisement from [mac], heard at [at].
ScanResult _adv(String mac, int rssi, DateTime at) => ScanResult(
      device: BluetoothDevice(remoteId: DeviceIdentifier(mac)),
      advertisementData: AdvertisementData(
        advName: 'peer-$mac',
        txPowerLevel: null,
        appearance: null,
        connectable: true,
        manufacturerData: const {},
        serviceData: const {},
        serviceUuids: const [],
      ),
      rssi: rssi,
      timeStamp: at,
    );

void main() {
  // Off-device: the scan callback is fed directly, the radio never starts
  // (setProximity on an unstarted scanner only records the flag).
  group('proximity emits', () {
    final t0 = DateTime(2026, 9, 23, 12);
    const a = 'AA:AA:AA:AA:AA:AA';
    const b = 'BB:BB:BB:BB:BB:BB';
    const later = Duration(milliseconds: 150);

    test('an unchanged RSSI still comes through, once per advertisement', () {
      fakeAsync((async) {
        final scanner = BleScanner(isIOS: false);
        final snapshots = <List<DiscoveredPeer>>[];
        scanner.peers.listen(snapshots.add);
        unawaited(scanner.setProximity(true));
        async.flushMicrotasks();

        scanner.debugOnResults([_adv(a, -35, t0)]);
        async.elapse(later);
        expect(snapshots, hasLength(1));

        // The same -35 again, from a new advertisement: a new snapshot.
        scanner.debugOnResults([
          _adv(a, -35, t0.add(const Duration(milliseconds: 250))),
        ]);
        async.elapse(later);
        expect(snapshots, hasLength(2));
        final aSeen = snapshots.last.single.lastSeen;

        // The platform handing the whole list over again because B spoke:
        // A's old advertisement is not a new reading of A.
        scanner.debugOnResults([
          _adv(a, -35, t0.add(const Duration(milliseconds: 250))),
          _adv(b, -80, t0.add(const Duration(milliseconds: 300))),
        ]);
        async.elapse(later);
        expect(snapshots, hasLength(3));
        expect(snapshots.last.firstWhere((p) => p.id == a).lastSeen, aSeen);

        // Nothing new at all: nothing emitted.
        scanner.debugOnResults([
          _adv(a, -35, t0.add(const Duration(milliseconds: 250))),
          _adv(b, -80, t0.add(const Duration(milliseconds: 300))),
        ]);
        async.elapse(later);
        expect(snapshots, hasLength(3));
      });
    });

    test('at most one snapshot per 100 ms, and the last change is not lost',
        () {
      fakeAsync((async) {
        final scanner = BleScanner(isIOS: false);
        final snapshots = <List<DiscoveredPeer>>[];
        scanner.peers.listen(snapshots.add);
        unawaited(scanner.setProximity(true));
        async.flushMicrotasks();

        for (var i = 0; i < 10; i++) {
          scanner.debugOnResults([
            _adv(a, -40 - i, t0.add(Duration(milliseconds: 5 * i))),
          ]);
          async.elapse(const Duration(milliseconds: 5));
        }
        // 50 ms in: only the leading snapshot.
        expect(snapshots, hasLength(1));
        async.elapse(const Duration(milliseconds: 100));
        expect(snapshots, hasLength(2));
        expect(snapshots.last.single.rssi, -49);
        async.elapse(const Duration(milliseconds: 500));
        expect(snapshots, hasLength(2));
      });
    });

    test('outside proximity an unmoved RSSI is still not news', () {
      fakeAsync((async) {
        final scanner = BleScanner(isIOS: false);
        final snapshots = <List<DiscoveredPeer>>[];
        scanner.peers.listen(snapshots.add);
        scanner
          ..debugOnResults([_adv(a, -60, t0)])
          ..debugOnResults([
            _adv(a, -60, t0.add(const Duration(milliseconds: 250))),
          ]);
        async.flushMicrotasks();
        expect(snapshots, hasLength(1));
      });
    });
  });

  test('proximity mode reports every decibel, normal mode only real moves',
      () {
    expect(BleConstants.rssiMoveThreshold(proximity: true), 1);
    expect(BleConstants.rssiMoveThreshold(proximity: false), 4);
  });

  test('proximity scanning barely pauses', () {
    expect(BleConstants.proximityGap, lessThan(const Duration(seconds: 1)));
    expect(
      BleConstants.proximityWindow,
      greaterThan(BleConstants.proximityGap),
    );
  });

  test(
      'setProximity on a scanner that was never started just records the '
      'flag — it does not start a scan', () async {
    // No platform channel is ever mocked here, so if setProximity() reached
    // FlutterBluePlus.startScan on an unstarted scanner this test would throw
    // MissingPluginException instead of passing quietly.
    final scanner = BleScanner(isIOS: false);
    await scanner.setProximity(true);
    expect(scanner.proximity, isTrue);
    expect(scanner.isRunning, isFalse);
  });
}
