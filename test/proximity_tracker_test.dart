import 'package:cubechat/features/airdrop/domain/proximity_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 9, 23, 12);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  test('one loud sample in a quiet second is not a bump', () {
    final p = ProximityTracker();
    for (var i = 0; i < 5; i++) {
      p.add('a', -70, at(i * 200));
    }
    p.add('a', -30, at(900));
    expect(p.read(at(1000)).isClose, isFalse);
  });

  test('a steady -35 with nobody else near is a bump', () {
    final p = ProximityTracker();
    for (var i = 0; i < 6; i++) {
      p.add('a', -35, at(i * 150));
    }
    final r = p.read(at(900));
    expect(r.isClose, isTrue);
    expect(r.closest, 'a');
    expect(r.warmth, 1.0);
  });

  test('two phones close together are not a bump', () {
    final p = ProximityTracker();
    for (var i = 0; i < 6; i++) {
      p
        ..add('a', -36, at(i * 150))
        ..add('b', -45, at(i * 150));
    }
    final r = p.read(at(900));
    expect(r.isClose, isFalse);
    expect(r.runnerUpRssi, -45);
  });

  test('silence is held for three seconds, then forgotten', () {
    final p = ProximityTracker()..add('a', -35, at(0));
    expect(p.read(at(2500)).closest, 'a');
    expect(p.read(at(3500)).closest, isNull);
  });

  test('warmth rises from -60 to -40', () {
    final p = ProximityTracker()..add('a', -50, at(0));
    expect(p.read(at(10)).warmth, closeTo(0.5, 0.001));
    final q = ProximityTracker()..add('a', -75, at(0));
    expect(q.read(at(10)).warmth, 0);
  });

  test('the 127 sentinel is not a reading', () {
    final p = ProximityTracker()..add('a', 127, at(0));
    expect(p.read(at(10)).closest, isNull);
  });
}
