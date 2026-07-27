import 'dart:typed_data';

import 'package:cubechat/core/transport/frame_fragment.dart';
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

  group('bleMediaChunkData', () {
    /// What the transport actually does with the budget: build a frame of
    /// `data + overhead` and hand it to the fragmenter for this link.
    int fragmentsFor(int data, int effectiveMtu) {
      final frame = Uint8List(data + kMediaChunkFrameOverhead);
      return fragmentFrame(frame, effectiveMtu).length;
    }

    test('reaches the target on a link that can carry it', () {
      // The real iOS<->Android link from the field log: 225 B usable.
      expect(bleMediaChunkData(225, ceiling: 16384), kBleMediaChunkData);
    });

    test('is enormously bigger than one write, which is the whole point', () {
      final oldWay = mediaChunkDataBudget(225, ceiling: 16384);
      final newWay = bleMediaChunkData(225, ceiling: 16384);
      expect(oldWay, lessThan(150), reason: 'the 101-byte chunks from the log');
      expect(newWay, greaterThan(oldWay * 20));
    });

    test('spends almost all of a chunk on payload rather than packaging', () {
      final data = bleMediaChunkData(225, ceiling: 16384);
      final overheadShare =
          kMediaChunkFrameOverhead / (data + kMediaChunkFrameOverhead);
      expect(
        overheadShare,
        lessThan(0.05),
        reason: 'it used to be 55% — that is what made a photo take minutes',
      );
    });

    test('never asks the fragmenter for more slices than it allows', () {
      // Every plausible link, plus absurd ones, must stay inside the cap —
      // exceeding it makes fragmentFrame throw and fails the whole transfer.
      for (var mtu = 20; mtu <= 517; mtu++) {
        final data = bleMediaChunkData(effectivePayload(mtu), ceiling: 16384);
        final frags = fragmentsFor(data, effectivePayload(mtu));
        expect(
          frags,
          lessThanOrEqualTo(kMaxFragments),
          reason: 'mtu $mtu produced $frags fragments for $data bytes',
        );
        expect(frags, lessThanOrEqualTo(kBleMaxFragmentsPerChunk));
      }
    });

    test('steps down rather than throwing on an absurdly narrow link', () {
      final data = bleMediaChunkData(20, ceiling: 16384);
      expect(data, lessThan(kBleMediaChunkData));
      expect(data, greaterThanOrEqualTo(kMinMediaChunkData));
    });

    test('respects the protocol ceiling', () {
      expect(bleMediaChunkData(225, ceiling: 512), 512);
    });
  });
}
