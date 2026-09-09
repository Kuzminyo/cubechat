import 'dart:async';

import 'package:cubechat/core/util/cost_meter.dart';
import 'package:cubechat/core/util/debug_log.dart';
import 'package:flutter_test/flutter_test.dart';

/// The meter for the six seconds nothing could account for.
///
/// A 43-second reading on a 120 Hz Android phone put `platform + Dart UI` at
/// 23% of a core while frames cost 1.0 ms of build — so most of that time was
/// Dart doing something other than drawing, and the tree had no way to say
/// what. These pin the two properties that make the answer readable: it adds
/// calls up instead of printing each one, and an idle app writes nothing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    DebugLog.install();
    DebugLog.instance.clear();
    CostMeter.instance.reset();
  });
  tearDown(() {
    CostMeter.instance.reset();
    DebugLog.instance.clear();
  });

  Iterable<String> costs() => DebugLog.instance.entries
      .map((e) => e.line)
      .where((l) => l.contains('COST'));

  void burn(Duration held) {
    final until = DateTime.now().add(held);
    while (DateTime.now().isBefore(until)) {
      // Synchronous on purpose: this is the shape of the work being measured,
      // a BIP-340 signature with no real suspension in it.
    }
  }

  test('many calls become one line, with the count and the total', () async {
    for (var i = 0; i < 5; i++) {
      await CostMeter.instance.measure('sign', () async {
        burn(const Duration(milliseconds: 3));
      });
    }
    await Future<void>.delayed(CostMeter.window + const Duration(seconds: 1));

    expect(costs(), hasLength(1),
        reason: 'a line per call would fill a 200-line buffer in seconds and '
            'evict the evidence it exists to collect');
    expect(costs().first, contains('sign 5×'));
  });

  test('the busiest name is named first', () async {
    await CostMeter.instance.measure('cheap', () async {
      burn(const Duration(milliseconds: 2));
    });
    await CostMeter.instance.measure('dear', () async {
      burn(const Duration(milliseconds: 20));
    });
    await Future<void>.delayed(CostMeter.window + const Duration(seconds: 1));

    final line = costs().first;
    expect(line.indexOf('dear'), lessThan(line.indexOf('cheap')));
  });

  test('an app doing nothing writes nothing', () async {
    await Future<void>.delayed(CostMeter.window + const Duration(seconds: 1));
    expect(costs(), isEmpty);
  });

  test('the timer stops itself once the traffic does', () async {
    await CostMeter.instance.measure('sign', () async {
      burn(const Duration(milliseconds: 5));
    });
    // One window prints, the next finds nothing and stands the timer down. A
    // periodic timer left running for the life of the process is exactly the
    // permanent cost an instrument must not add.
    await Future<void>.delayed(CostMeter.window * 2 + const Duration(seconds: 1));
    expect(costs(), hasLength(1));
  });
}
