import 'dart:typed_data';

import 'package:cubechat/features/call/domain/call_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 10, 12, 0, 0);
  int msAgo(Duration d) => now.subtract(d).millisecondsSinceEpoch;

  group('invite freshness', () {
    test('an invite sent a moment ago is fresh', () {
      expect(
        inviteIsFresh(sentAtMs: msAgo(const Duration(seconds: 2)), now: now),
        isTrue,
      );
    });

    test('an invite from an hour ago is not', () {
      // Relays hold events and hand them over on connect, so an invite from an
      // hour ago arrives looking new. A phone that rings an hour after a call
      // that never happened is a ghost, and this is the line that stops it.
      expect(
        inviteIsFresh(sentAtMs: msAgo(const Duration(hours: 1)), now: now),
        isFalse,
      );
    });

    test('the boundary itself is still fresh', () {
      expect(
        inviteIsFresh(sentAtMs: msAgo(CallTimings.inviteFreshness), now: now),
        isTrue,
      );
    });

    test('one millisecond past the boundary is not', () {
      expect(
        inviteIsFresh(
          sentAtMs: msAgo(CallTimings.inviteFreshness) - 1,
          now: now,
        ),
        isFalse,
      );
    });

    test('a clock a little ahead of ours is tolerated, a lot is not', () {
      // Phone clocks disagree. A few seconds of drift must not kill a real
      // call; a timestamp days in the future is not drift, it is nonsense.
      expect(
        inviteIsFresh(
          sentAtMs: now.add(const Duration(seconds: 5)).millisecondsSinceEpoch,
          now: now,
        ),
        isTrue,
      );
      expect(
        inviteIsFresh(
          sentAtMs: now.add(const Duration(days: 1)).millisecondsSinceEpoch,
          now: now,
        ),
        isFalse,
      );
    });
  });

  group('glare', () {
    Uint8List idOf(List<int> head) => Uint8List.fromList(
          [...head, ...List.filled(callIdLen - head.length, 0)],
        );

    test('the smaller id wins, and both sides agree', () {
      final low = idOf([0x01]);
      final high = idOf([0x02]);
      expect(winsGlare(mine: low, theirs: high), isTrue);
      expect(winsGlare(mine: high, theirs: low), isFalse);
    });

    test('the comparison reads past the first byte', () {
      final a = idOf([0x05, 0x01]);
      final b = idOf([0x05, 0x02]);
      expect(winsGlare(mine: a, theirs: b), isTrue);
      expect(winsGlare(mine: b, theirs: a), isFalse);
    });

    test('two identical ids are not a contest either side wins', () {
      // Sixteen random bytes never collide in practice. If they did, both
      // sides deciding "I win" would leave two half-calls, so both lose.
      final same = idOf([0x09]);
      expect(winsGlare(mine: same, theirs: same), isFalse);
    });
  });
}
