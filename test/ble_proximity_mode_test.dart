import 'dart:async';

import 'package:cubechat/core/ble/ble_constants.dart';
import 'package:cubechat/core/ble/ble_scan_platform.dart';
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

    test('results landing while dispose() awaits leave no emit behind', () {
      fakeAsync((async) {
        final scanner = BleScanner(isIOS: false);
        final snapshots = <List<DiscoveredPeer>>[];
        scanner.peers.listen(snapshots.add);
        unawaited(scanner.setProximity(true));
        async.flushMicrotasks();

        // dispose() runs stop(), which yields at its first await; two
        // results arrive in that gap and arm the throttle with a trailing
        // emit pending.
        unawaited(scanner.dispose());
        scanner
          ..debugOnResults([_adv(a, -35, t0)])
          ..debugOnResults([
            _adv(a, -36, t0.add(const Duration(milliseconds: 10))),
          ]);
        async.flushMicrotasks();
        // And one after the stream has closed.
        scanner.debugOnResults([
          _adv(a, -37, t0.add(const Duration(milliseconds: 20))),
        ]);
        // A trailing emit into the closed stream would throw right here.
        async.elapse(const Duration(milliseconds: 300));
        expect(async.pendingTimers, isEmpty);
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

  group('scan-start budget', () {
    final t0 = DateTime(2026, 9, 24, 12);
    DateTime at(int s) => t0.add(Duration(seconds: s));

    test('four starts in 30 s are free; the fifth waits for the oldest', () {
      final b = ScanStartBudget();
      for (final s in [0, 5, 10, 15]) {
        expect(b.waitBefore(at(s)), Duration.zero);
        b.record(at(s));
      }
      // Android goes quiet after the fifth start in 30 s: hold it until the
      // start at 0 s has aged out.
      expect(
        b.waitBefore(at(20)),
        greaterThanOrEqualTo(const Duration(seconds: 10)),
      );
      expect(b.waitBefore(at(20)), lessThan(const Duration(seconds: 11)));
      expect(b.waitBefore(at(31)), Duration.zero);
    });

    test('old starts are forgotten', () {
      final b = ScanStartBudget();
      for (var s = 0; s < 40; s += 10) {
        b.record(at(s));
      }
      expect(b.waitBefore(at(41)), Duration.zero);
    });
  });

  test('the proximity window is long enough not to rotate', () {
    // 10.3 s windows were three starts in 30 s on their own, before any
    // arrival on the page added more.
    expect(
      BleConstants.proximityWindow,
      greaterThanOrEqualTo(const Duration(seconds: 25)),
    );
  });

  group('starts against a fake radio', () {
    test('a retune and a proximity switch at once start one scan, one '
        'listener', () {
      fakeAsync((async) {
        DateTime now() => DateTime(2026, 9, 24, 12).add(async.elapsed);
        final radio = _FakeRadio(now);
        var active = true;
        final scanner = BleScanner(isIOS: false, platform: radio, now: now)
          ..shouldScanActively = () => active;
        unawaited(scanner.start());
        async.elapse(const Duration(milliseconds: 500));
        expect(radio.starts, hasLength(1));

        // What a resume on the AirDrop page does: both arrive together.
        active = false;
        unawaited(scanner.retune());
        unawaited(scanner.setProximity(true));
        async.elapse(const Duration(seconds: 1));
        expect(radio.maxInFlight, 1);
        expect(radio.listeners, 1);
        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });

    test(
        'iOS restarts at once even with a full budget — Android would hold',
        () {
      fakeAsync((async) {
        DateTime now() => DateTime(2026, 9, 24, 12).add(async.elapsed);
        final radio = _FakeRadio(now);
        var active = true;
        final scanner = BleScanner(isIOS: true, platform: radio, now: now)
          ..shouldScanActively = () => active;
        unawaited(scanner.start());
        async.elapse(const Duration(milliseconds: 200));

        // Fill the budget to four starts via retune, well inside 30 s —
        // proximity untouched so far.
        for (final next in [false, true, false, true]) {
          active = next;
          unawaited(scanner.retune());
          async.elapse(const Duration(seconds: 1));
        }
        final before = radio.starts.length;
        expect(before, greaterThanOrEqualTo(4));

        // On Android this would be held (see the test above); iOS applies no
        // ScanStartBudget at all, so it restarts in this same tick.
        unawaited(scanner.setProximity(true));
        async.elapse(const Duration(milliseconds: 10));
        expect(radio.starts.length, before + 1);
        expect(scanner.proximity, isTrue);

        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });

    test(
        'the held timer skips its restart once the running window already '
        'reopened on the proximity cadence', () {
      fakeAsync((async) {
        DateTime now() => DateTime(2026, 9, 24, 12).add(async.elapsed);
        final radio = _FakeRadio(now);
        var active = true;
        final scanner = BleScanner(isIOS: false, platform: radio, now: now)
          ..shouldScanActively = () => active;
        unawaited(scanner.start());
        async.elapse(const Duration(milliseconds: 200));

        // Five starts inside 30 s, ending on the active cadence (10 s window
        // + 4 s gap = a 14 s cycle) so the window open when setProximity is
        // called restarts itself well before any held timer would.
        for (final next in [false, true, false, true]) {
          active = next;
          unawaited(scanner.retune());
          async.elapse(const Duration(seconds: 1));
        }
        expect(radio.starts.length, greaterThanOrEqualTo(4));

        // Over budget: held, not restarted immediately.
        unawaited(scanner.setProximity(true));
        async.elapse(const Duration(milliseconds: 50));
        final afterHold = radio.starts.length;

        // The window already running (active cadence, ~14 s cycle) reaches
        // the end of its own cycle and restarts itself — landing on the
        // proximity cadence, since setProximity(true) already flipped the
        // flag — well before the ~26 s the budget is making the held timer
        // wait out.
        async.elapse(const Duration(seconds: 15));
        final afterNaturalRestart = radio.starts.length;
        expect(afterNaturalRestart, afterHold + 1);

        // The held timer itself now fires (comfortably before it would have,
        // in real time — elapse well past its scheduled wait) and must find
        // nothing left to do: no second, redundant start.
        async.elapse(const Duration(seconds: 20));
        expect(radio.starts.length, afterNaturalRestart);
        expect(scanner.proximity, isTrue);

        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });

    // Build 1112's log: the page came back from two pauses in ten seconds,
    // and every resume on it cost two starts — the retune's and the
    // proximity switch's, neither aware of the other — on top of the window
    // still open. After the fifth start in 30 s Android hands an app no scan
    // results at all for that scan, and the phone held against this one was
    // never read at bump distance.
    test('a resume on the AirDrop page keeps the proximity window it left',
        () {
      fakeAsync((async) {
        DateTime now() => DateTime(2026, 9, 24, 12).add(async.elapsed);
        final radio = _FakeRadio(now);
        var active = true;
        final scanner = BleScanner(isIOS: false, platform: radio, now: now)
          ..shouldScanActively = () => active;
        unawaited(scanner.start());
        async.elapse(const Duration(milliseconds: 200));
        unawaited(scanner.setProximity(true));
        async.elapse(const Duration(seconds: 3));
        final before = radio.starts.length;
        expect(radio.lastModeLowLatency, isTrue);

        // The shade pulled down and pushed back: paused, then resumed.
        unawaited(scanner.setProximity(false));
        async.elapse(const Duration(milliseconds: 300));
        active = false;
        unawaited(scanner.retune());
        unawaited(scanner.setProximity(true));
        async.elapse(const Duration(seconds: 1));

        expect(radio.starts.length, before);
        expect(scanner.proximity, isTrue);
        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });

    test('a retune already queued carries the proximity switch: one start',
        () {
      fakeAsync((async) {
        DateTime now() => DateTime(2026, 9, 24, 12).add(async.elapsed);
        final radio = _FakeRadio(now);
        var active = true;
        final scanner = BleScanner(isIOS: false, platform: radio, now: now)
          ..shouldScanActively = () => active;
        unawaited(scanner.start());
        async.elapse(const Duration(milliseconds: 500));
        final before = radio.starts.length;

        active = false;
        unawaited(scanner.retune());
        unawaited(scanner.setProximity(true));
        async.elapse(const Duration(seconds: 1));

        expect(radio.starts.length, before + 1);
        expect(radio.lastModeLowLatency, isTrue);
        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });

    test(
        'a proximity window that hears nothing while a phone is listed '
        'restarts once, and again only after something was heard', () {
      fakeAsync((async) {
        DateTime now() => DateTime(2026, 9, 24, 12).add(async.elapsed);
        final radio = _FakeRadio(now);
        final scanner = BleScanner(isIOS: false, platform: radio, now: now);
        unawaited(scanner.start());
        async.elapse(const Duration(milliseconds: 200));
        scanner.debugOnResults([_adv('AA:AA:AA:AA:AA:AA', -60, now())]);
        unawaited(scanner.setProximity(true));
        async.elapse(const Duration(seconds: 1));
        final opened = radio.starts.length;
        expect(scanner.advertsLastSecond, 0);

        // Silence from a scan that should be hearing that phone several
        // times a second: restarted, once.
        async.elapse(BleScanner.blindAfter + const Duration(seconds: 1));
        expect(radio.starts.length, opened + 1);
        expect(radio.lastModeLowLatency, isTrue);
        async.elapse(const Duration(seconds: 10));
        expect(radio.starts.length, opened + 1);

        // Heard again: counted, and a later silence may restart again.
        scanner.debugOnResults([_adv('AA:AA:AA:AA:AA:AA', -40, now())]);
        expect(scanner.advertsLastSecond, 1);
        async.elapse(const Duration(seconds: 2));
        expect(scanner.advertsLastSecond, 0);
        async.elapse(BleScanner.blindAfter);
        expect(radio.starts.length, opened + 2);
        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });

    test('toggling proximity never makes a fifth start in 30 s', () {
      fakeAsync((async) {
        DateTime now() => DateTime(2026, 9, 24, 12).add(async.elapsed);
        final radio = _FakeRadio(now);
        final scanner = BleScanner(isIOS: false, platform: radio, now: now);
        unawaited(scanner.start());
        async.elapse(const Duration(milliseconds: 200));
        for (var i = 0; i < 6; i++) {
          unawaited(scanner.setProximity(true));
          async.elapse(const Duration(seconds: 1));
          unawaited(scanner.setProximity(false));
          async.elapse(const Duration(seconds: 1));
        }
        unawaited(scanner.setProximity(true));
        async.elapse(const Duration(seconds: 1));
        bool within30(DateTime a) =>
            now().difference(a) < const Duration(seconds: 30);
        expect(radio.starts.where(within30).length, lessThanOrEqualTo(4));

        // The postponed start still comes, once the oldest ages out.
        final before = radio.starts.length;
        async.elapse(const Duration(seconds: 25));
        expect(radio.starts.length, greaterThan(before));
        expect(scanner.proximity, isTrue);
        expect(radio.lastModeLowLatency, isTrue);
        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });
  });
}

/// A radio that takes 50 ms to start a scan, counting overlapping starts and
/// live result listeners.
class _FakeRadio extends BleScanPlatform {
  _FakeRadio(this.now);

  final DateTime Function() now;
  final starts = <DateTime>[];
  int _inFlight = 0;
  int maxInFlight = 0;
  int listeners = 0;
  bool _scanning = false;
  bool lastModeLowLatency = false;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      Stream.value(BluetoothAdapterState.on);

  @override
  bool get isOn => true;

  @override
  bool get isScanning => _scanning;

  @override
  Future<void> startScan({
    required Duration timeout,
    required AndroidScanMode mode,
    required bool continuousUpdates,
  }) async {
    _inFlight++;
    if (_inFlight > maxInFlight) maxInFlight = _inFlight;
    starts.add(now());
    lastModeLowLatency = mode == AndroidScanMode.lowLatency;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _inFlight--;
    _scanning = true;
  }

  @override
  Future<void> stopScan() async => _scanning = false;

  @override
  Stream<List<ScanResult>> get scanResults => Stream.multi((c) {
        listeners++;
        // A future of this zone: a bare void onCancel makes cancel() hand
        // back a root-zone future that fakeAsync never completes.
        c.onCancel = () async {
          listeners--;
        };
      });
}
