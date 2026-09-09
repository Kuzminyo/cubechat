import 'dart:async';

import 'debug_log.dart';

/// Adds up Dart time by name and prints one line for all of it.
///
/// **Why this and not [MessagingService._timed], which already exists.** That
/// one prints a line per call and is right for something that happens when you
/// open a chat. The relay path is not that: publishing a frame and verifying an
/// inbound one happen tens of times a second, so a line each would fill a
/// 200-line buffer in about three seconds and evict the evidence it was written
/// to collect. What is wanted here is not any single call, it is the total.
///
/// **The measurement that asked for it.** Forty-three seconds of ordinary use
/// on a 120 Hz Android phone, read off the Diagnostics panel: 73% of a core,
/// of which the rasterizer was 35% and `platform + Dart UI` was 23%. Frames
/// were healthy — 1.0 ms of build, 4.3 ms of raster, 37 slow out of 4277 — and
/// roughly 3500 frames at 1.0 ms accounts for about three and a half of those
/// nine and a half seconds. The other six are Dart doing something that is not
/// drawing, and nothing in the tree could say what.
///
/// **Two numbers, because the difference is the answer.** `sync` is the part
/// that ran before the first real suspension, which is the part a frame pays
/// for. `wall` includes waiting on a socket, which costs nothing to look at.
/// BIP-340 is implemented in Dart in this repo and has no suspension in it
/// worth the name, so a signature is sync time in full — and `Secp256k1.sign`
/// verifies what it just produced, so one publish is a sign *and* a verify.
class CostMeter {
  CostMeter._();
  static final CostMeter instance = CostMeter._();

  /// How often the totals are printed. Long enough that the line is a summary
  /// rather than a stream, short enough to line up with what you were doing.
  static const Duration window = Duration(seconds: 5);

  /// Below this the window is not worth a line. An app sitting still should
  /// write nothing at all, or the buffer fills with reports of idleness.
  static const int _floorUs = 2000;

  final Map<String, _Tally> _tallies = {};
  Timer? _flush;

  /// Time [run] under [what]. Returns whatever it returned.
  Future<T> measure<T>(String what, Future<T> Function() run) {
    final clock = Stopwatch()..start();
    final future = run();
    final syncUs = clock.elapsedMicroseconds;
    return future.whenComplete(() {
      _record(what, syncUs: syncUs, wallUs: clock.elapsedMicroseconds);
    });
  }

  void _record(String what, {required int syncUs, required int wallUs}) {
    final tally = _tallies.putIfAbsent(what, _Tally.new);
    tally.calls++;
    tally.syncUs += syncUs;
    tally.wallUs += wallUs;
    _flush ??= Timer.periodic(window, (_) => _report());
  }

  void _report() {
    if (_tallies.isEmpty) {
      // Nothing happened for a whole window: stop asking. The timer restarts
      // itself on the next thing measured.
      _flush?.cancel();
      _flush = null;
      return;
    }
    final rows = _tallies.entries.toList()
      ..sort((a, b) => b.value.syncUs.compareTo(a.value.syncUs));
    final totalSync = rows.fold<int>(0, (sum, e) => sum + e.value.syncUs);
    _tallies.clear();
    if (totalSync < _floorUs) return;
    final parts = rows.map((e) {
      final t = e.value;
      return '${e.key} ${t.calls}× ${_ms(t.syncUs)} sync/${_ms(t.wallUs)} wall';
    }).join(', ');
    DebugLog.instance.log(
      'COST',
      'last ${window.inSeconds}s — ${_ms(totalSync)} of Dart: $parts',
    );
  }

  static String _ms(int us) => '${(us / 1000).toStringAsFixed(0)} ms';

  /// For tests, and for a teardown that must leave no timer behind.
  void reset() {
    _flush?.cancel();
    _flush = null;
    _tallies.clear();
  }
}

class _Tally {
  int calls = 0;
  int syncUs = 0;
  int wallUs = 0;
}
