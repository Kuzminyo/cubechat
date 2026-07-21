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

  group('idle back-off when nobody is around', () {
    Duration backoff(int emptyWindows, {Duration? base}) =>
        BleConstants.idleGapWithBackoff(
          base: base ?? BleConstants.scanGapIdleIos,
          emptyWindows: emptyWindows,
        );

    test('stays at the base gap until the threshold is crossed', () {
      // The common case — someone is around, or has only just stopped being
      // seen — must be completely untouched by this.
      for (var n = 0; n <= BleConstants.idleBackoffAfterEmptyWindows; n++) {
        expect(
          backoff(n),
          BleConstants.scanGapIdleIos,
          reason: '$n empty windows should not have backed off yet',
        );
      }
    });

    test('grows past the threshold and never exceeds the cap', () {
      final first = backoff(BleConstants.idleBackoffAfterEmptyWindows + 1);
      expect(first, greaterThan(BleConstants.scanGapIdleIos));
      // Monotonic, and pinned under the ceiling however long we go unseen.
      var previous = first;
      for (var n = BleConstants.idleBackoffAfterEmptyWindows + 2;
          n < 40;
          n++) {
        final gap = backoff(n);
        expect(gap, greaterThanOrEqualTo(previous));
        expect(gap, lessThanOrEqualTo(BleConstants.idleGapMax));
        previous = gap;
      }
      // And it actually reaches the cap rather than creeping forever.
      expect(backoff(40), BleConstants.idleGapMax);
    });

    test('works from the Android base gap too', () {
      expect(backoff(0, base: BleConstants.scanGapIdle),
          BleConstants.scanGapIdle);
      expect(
        backoff(40, base: BleConstants.scanGapIdle),
        BleConstants.idleGapMax,
      );
    });

    test('the cap is reachable without starving discovery outright', () {
      // The bound that makes the trade arguable: even fully backed off we
      // still look, and a peer who walks up is noticed within the cap. If
      // someone raises idleGapMax into "effectively off" territory, this is
      // the assertion that should stop them and force the re-argument.
      expect(BleConstants.idleGapMax, lessThanOrEqualTo(const Duration(minutes: 5)));
      expect(BleConstants.idleGapMax, greaterThan(BleConstants.scanGapIdleIos));
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

    test('active: finds a peer sooner than Android despite scanning less', () {
      // What makes the *active* iOS shape a free win rather than a trade:
      // discovery latency is bounded by the cycle, not the window, so a shorter
      // cycle beats a longer one even though the radio is on for less of it.
      // Still holds while the user is watching the Nearby list.
      final iosCycle = window(active: true) + gap(active: true);
      final androidCycle = androidWindow(active: true) + androidGap(active: true);
      expect(iosCycle, lessThan(androidCycle));
    });

    test('idle: trades discovery latency for far fewer scan restarts', () {
      // The idle half deliberately gives up that property — this is the
      // re-argument the old "cycle must stay shorter" assertion demanded.
      //
      // Duty cycle was never the iOS problem (iOS already scans less than
      // Android at both cadences, below). The cost was per-cycle CoreBluetooth
      // session churn on a process iOS never suspends, so the fix is a longer
      // cycle, not a smaller window. Advertising is continuous and independent
      // of scanning, so we stay discoverable to the foreground peer who is
      // actually looking for us the whole time.
      final iosCycle = window(active: false) + gap(active: false);
      final androidCycle =
          androidWindow(active: false) + androidGap(active: false);
      expect(iosCycle, greaterThan(androidCycle));
      // Still cheaper on radio time than Android, despite the longer cycle.
      expect(
        dutyCycle(window(active: false), gap(active: false)),
        lessThan(dutyCycle(BleConstants.scanWindowIdle, BleConstants.scanGapIdle)),
      );
    });

    test('a peer survives a missed window at either cadence', () {
      // The invariant that broke when the idle cadence first landed. The idle
      // threshold is now platform-specific precisely to keep it true here: the
      // shared 75 s one is under a single 60 s iOS idle cycle plus its window.
      expect(
        BleConstants.peerStaleAfterFor(active: true, isIOS: true),
        greaterThan((window(active: true) + gap(active: true)) * 2),
      );
      expect(
        BleConstants.peerStaleAfterFor(active: false, isIOS: true),
        greaterThan((window(active: false) + gap(active: false)) * 2),
      );
    });

    test('the stale selector routes each platform to its own idle number', () {
      expect(
        BleConstants.peerStaleAfterFor(active: false, isIOS: true),
        BleConstants.peerStaleAfterIdleIos,
      );
      expect(
        BleConstants.peerStaleAfterFor(active: false, isIOS: false),
        BleConstants.peerStaleAfterIdle,
      );
      // Active is shared — one number for both platforms.
      expect(
        BleConstants.peerStaleAfterFor(active: true, isIOS: true),
        BleConstants.peerStaleAfterFor(active: true, isIOS: false),
      );
    });
  });
}
