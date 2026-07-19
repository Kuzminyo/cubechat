import 'package:cubechat/core/transport/mtu_budget.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('effectivePayload', () {
    test('subtracts ATT header + safety margin', () {
      expect(effectivePayload(247), 247 - kAttHeaderBytes - kMtuSafetyMargin);
      expect(effectivePayload(210), 210 - kAttHeaderBytes - kMtuSafetyMargin);
    });

    test('never returns below the 20-byte floor', () {
      expect(effectivePayload(23), 20);
      expect(effectivePayload(0), 20);
    });

    test('conservative default matches the iPhone-floor MTU', () {
      expect(conservativeEffectivePayload(), effectivePayload(kConservativeAttMtu));
      // Must stay comfortably below the ~207-effective link that failed in the
      // field logs, so fan-out / peripheral sends are safe by default.
      expect(conservativeEffectivePayload(), lessThan(200));
    });
  });

  group('mediaChunkDataBudget', () {
    test('a full frame at the budget fits the effective MTU', () {
      for (final mtu in [185, 210, 247, 517]) {
        final e = effectivePayload(mtu);
        final data = mediaChunkDataBudget(e, ceiling: 140);
        // Reconstruct the worst-case frame size and assert it fits.
        expect(data + kMediaChunkFrameOverhead, lessThanOrEqualTo(e),
            reason: 'mtu=$mtu e=$e data=$data');
      }
    });

    test('clamps up to the floor on a tiny MTU', () {
      expect(mediaChunkDataBudget(50, ceiling: 140), kMinMediaChunkData);
    });

    test('clamps down to the protocol ceiling on a large MTU', () {
      expect(mediaChunkDataBudget(effectivePayload(517), ceiling: 140), 140);
      expect(mediaChunkDataBudget(effectivePayload(517), ceiling: 136), 136);
    });

    test('the observed ~207-effective link yields a sub-140 budget', () {
      // 210 negotiated -> ~199 effective; the old fixed 140 overflowed, the new
      // budget must be strictly smaller so the frame fits.
      final data = mediaChunkDataBudget(effectivePayload(210), ceiling: 140);
      expect(data, lessThan(140));
      expect(data, greaterThanOrEqualTo(kMinMediaChunkData));
    });
  });

  group('fsTextWireCeiling', () {
    test('is the effective payload', () {
      expect(fsTextWireCeiling(199), 199);
    });
  });
}
