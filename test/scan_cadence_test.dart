import 'package:cubechat/core/ble/ble_constants.dart';
import 'package:flutter_test/flutter_test.dart';

/// The scan cadence is pure arithmetic over [BleConstants], so the trade it
/// makes can be pinned down without a radio. The scanner itself needs
/// FlutterBluePlus and can't run here; what these lock in is the *shape* of
/// the deal — idle must be materially cheaper than active, and the stale
/// threshold must outlast a whole cycle at whichever cadence is running.
void main() {
  double dutyCycle(Duration window, Duration gap) =>
      window.inMilliseconds / (window + gap).inMilliseconds;

  group('active cadence', () {
    test('keeps discovery prompt', () {
      // The user is watching the Nearby list — a peer should turn up fast.
      expect(BleConstants.scanWindow, const Duration(seconds: 10));
      expect(BleConstants.scanGap, const Duration(seconds: 4));
      expect(dutyCycle(BleConstants.scanWindow, BleConstants.scanGap),
          closeTo(0.71, 0.01));
    });

    test('a peer survives one missed window', () {
      // Regression guard: the threshold has to clear a full cycle with slack,
      // or a peer that is still right there blinks out of the list between
      // windows.
      final cycle = BleConstants.scanWindow + BleConstants.scanGap;
      expect(BleConstants.peerStaleAfter, greaterThan(cycle * 2));
    });
  });

  group('idle cadence', () {
    test('costs materially less radio time than active', () {
      final active = dutyCycle(BleConstants.scanWindow, BleConstants.scanGap);
      final idle =
          dutyCycle(BleConstants.scanWindowIdle, BleConstants.scanGapIdle);
      expect(idle, closeTo(0.20, 0.01));
      // The whole point of the idle cadence — if it ever creeps up to within
      // reach of the active one it has stopped earning its complexity.
      expect(idle, lessThan(active / 3));
    });

    test('stale threshold outlasts a full idle cycle', () {
      // This is the bug the idle cadence would otherwise introduce: a 30 s
      // cycle against the active 30 s threshold expires peers that never left.
      final cycle = BleConstants.scanWindowIdle + BleConstants.scanGapIdle;
      expect(BleConstants.peerStaleAfterIdle, greaterThan(cycle * 2));
      expect(BleConstants.peerStaleAfterIdle,
          greaterThan(BleConstants.peerStaleAfter));
    });
  });

  group('iOS cadence', () {
    Duration window({required bool active}) =>
        BleConstants.scanWindowFor(active: active, isIOS: true);
    Duration gap({required bool active}) =>
        BleConstants.scanGapFor(active: active, isIOS: true);
    Duration androidWindow({required bool active}) =>
        BleConstants.scanWindowFor(active: active, isIOS: false);
    Duration androidGap({required bool active}) =>
        BleConstants.scanGapFor(active: active, isIOS: false);

    test('the selectors route each platform to its own numbers', () {
      expect(androidWindow(active: true), BleConstants.scanWindow);
      expect(androidGap(active: true), BleConstants.scanGap);
      expect(androidWindow(active: false), BleConstants.scanWindowIdle);
      expect(androidGap(active: false), BleConstants.scanGapIdle);
      expect(window(active: true), BleConstants.scanWindowIos);
      expect(gap(active: true), BleConstants.scanGapIos);
      expect(window(active: false), BleConstants.scanWindowIdleIos);
      expect(gap(active: false), BleConstants.scanGapIdleIos);
    });

    test('spends less radio time than Android at both cadences', () {
      // CoreBluetooth reports each peer once per scan session, so the tail of
      // a long window is receive time that cannot learn anything new.
      for (final active in [true, false]) {
        final ios = dutyCycle(window(active: active), gap(active: active));
        final android = dutyCycle(
          androidWindow(active: active),
          androidGap(active: active),
        );
        expect(
          ios,
          lessThan(android),
          reason: 'iOS should idle the radio more than Android '
              '(active=$active)',
        );
      }
    });

    test('finds a peer sooner than Android despite scanning less', () {
      // The point of the iOS shape, and the thing that makes it a free win
      // rather than a trade: discovery latency is bounded by the cycle, not
      // the window, so a shorter cycle beats a longer one even though the
      // radio is on for less of it. If a future tuning pass ever inverts
      // this, the change has stopped being free and needs re-arguing.
      for (final active in [true, false]) {
        final iosCycle = window(active: active) + gap(active: active);
        final androidCycle =
            androidWindow(active: active) + androidGap(active: active);
        expect(
          iosCycle,
          lessThan(androidCycle),
          reason: 'iOS cycle must stay shorter (active=$active)',
        );
      }
    });

    test('a peer survives a missed window at either cadence', () {
      // The stale thresholds are shared with Android rather than scaled to the
      // shorter iOS cycles, so the margin here is generous — but it is exactly
      // the invariant that broke when the idle cadence first landed, so pin it
      // for iOS too.
      expect(
        BleConstants.peerStaleAfter,
        greaterThan((window(active: true) + gap(active: true)) * 2),
      );
      expect(
        BleConstants.peerStaleAfterIdle,
        greaterThan((window(active: false) + gap(active: false)) * 2),
      );
    });
  });
}
