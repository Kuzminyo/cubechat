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
}
