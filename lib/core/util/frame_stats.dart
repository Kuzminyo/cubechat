import 'dart:async';
import 'dart:ui' show FrameTiming;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/scheduler.dart';

/// Where a frame's time actually goes, measured rather than guessed.
///
/// Two rounds of tuning this app for heat were argued from reading the code,
/// and both times the thing that looked expensive was not the thing that was.
/// The reason is that "slow" has two completely different causes and they are
/// indistinguishable from the source:
///
///   * **build** is the UI thread — Dart. Widget rebuilds, layout, provider
///     churn, image decodes, anything synchronous in `build()`.
///   * **raster** is the GPU thread. Blurs, gradients, overdraw, saveLayer,
///     shader compilation. Almost none of it is visible in Dart at all.
///
/// A phone that is hot with raster at 14 ms and build at 2 ms will not get one
/// degree cooler from removing work in `build()`, however real that work was —
/// and that is precisely the mistake this class exists to stop repeating. The
/// numbers below are read off [SchedulerBinding.addTimingsCallback], which is
/// the framework's own instrumentation and costs nothing to leave running: the
/// engine reports each frame once it is already done.
///
/// Budget for reference: 16.7 ms per frame at 60 Hz, 8.3 ms at 120 Hz. Either
/// number exceeding the budget drops frames; whichever is *larger* is the one
/// worth working on.
class FrameStats {
  FrameStats._();

  static final FrameStats instance = FrameStats._();

  /// Rolling window. Big enough to survive a scroll's worth of variation,
  /// small enough that it reflects what is on screen now rather than what was
  /// a minute ago.
  static const int _window = 180;

  final List<int> _buildUs = <int>[];
  final List<int> _rasterUs = <int>[];

  bool _listening = false;
  int _total = 0;

  /// Frames whose raster or build overran a 60 Hz budget.
  int _janky = 0;

  /// Frames before this are dropped on the floor: they are the ones spent
  /// arriving.
  DateTime? _collectFrom;

  /// How long to look away for after starting.
  ///
  /// The panel begins measuring as the screen it lives on is still sliding in,
  /// so the first frames it sees are a route transition over a full-screen
  /// glass background — the most expensive thing this app ever draws, and over
  /// in a moment. They were counted, and on a slow phone they put an alarming
  /// red number at the top of the panel for the three seconds it took the
  /// rolling window to flush them out. That number described opening
  /// Diagnostics, not the app.
  static const Duration _warmUp = Duration(milliseconds: 700);

  void start() {
    if (_listening) return;
    _listening = true;
    _collectFrom = DateTime.now().add(_warmUp);
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  /// Whether frames are being collected. False means the engine is not calling
  /// us at all, which is what a screen nobody is looking at should cost.
  bool get isRunning => _listening;

  void stop() {
    if (!_listening) return;
    _listening = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  Timer? _holdTimer;
  DateTime? _holdEnds;

  /// Keep measuring after the panel that started it has gone away.
  ///
  /// The panel measures whatever is on screen, and what is on screen while you
  /// are reading the panel *is* the panel — a static list, on a phone that has
  /// just stopped scrolling. So the two screens anybody has ever reported as
  /// warm, a conversation being scrolled and the list of them, could not be
  /// measured from here at all. "The phone heats while I scroll" and
  /// "Diagnostics renders at 3 ms" were both true and about different things.
  ///
  /// Arm it, walk to the screen that is warm, use it, come back and read the
  /// numbers. It closes itself after [duration] whether or not anybody returns,
  /// because a timings callback left running for the life of the process is
  /// exactly the permanent cost the panel's own `dispose` was written to avoid.
  void hold(Duration duration) {
    reset();
    stop();
    start();
    _holdTimer?.cancel();
    _holdEnds = DateTime.now().add(duration);
    _holdTimer = Timer(duration, () {
      _holdTimer = null;
      _holdEnds = null;
      stop();
    });
  }

  /// True while a [hold] window is open — the panel reads this to know it must
  /// not stop collection on its way out.
  bool get isHolding => _holdTimer != null;

  /// How much of the window is left, for the panel to count down.
  Duration get holdRemaining {
    final ends = _holdEnds;
    if (ends == null) return Duration.zero;
    final left = ends.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// End the window early — the measurement is taken, stop paying for it.
  void releaseHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _holdEnds = null;
  }

  void reset() {
    _buildUs.clear();
    _rasterUs.clear();
    _total = 0;
    _janky = 0;
  }

  /// Feed timings in as if the engine had reported them. The engine's own
  /// callback list is not reachable from a test, and the two rules worth
  /// pinning down here — that the frames spent arriving are discarded, and
  /// that a stopped panel costs nothing — are both about what this does with
  /// what it is given.
  @visibleForTesting
  void ingestForTest(List<FrameTiming> timings) => _onTimings(timings);

  void _onTimings(List<FrameTiming> timings) {
    final from = _collectFrom;
    if (from != null) {
      if (DateTime.now().isBefore(from)) return;
      _collectFrom = null;
    }
    for (final t in timings) {
      final build = t.buildDuration.inMicroseconds;
      final raster = t.rasterDuration.inMicroseconds;
      _buildUs.add(build);
      _rasterUs.add(raster);
      _total++;
      if (build > 16700 || raster > 16700) _janky++;
      if (_buildUs.length > _window) _buildUs.removeAt(0);
      if (_rasterUs.length > _window) _rasterUs.removeAt(0);
    }
  }

  bool get hasSamples => _buildUs.isNotEmpty;
  int get sampleCount => _buildUs.length;
  int get totalFrames => _total;
  int get jankyFrames => _janky;

  double get avgBuildMs => _avg(_buildUs);
  double get avgRasterMs => _avg(_rasterUs);
  double get p90BuildMs => _p90(_buildUs);
  double get p90RasterMs => _p90(_rasterUs);

  /// Which thread to go and work on, in one word — the whole point of the
  /// screen this feeds.
  String get verdict {
    if (!hasSamples) return 'no frames measured yet';
    final b = p90BuildMs;
    final r = p90RasterMs;
    if (b < 8 && r < 8) return 'both threads inside a 120 Hz budget';
    if (r > b * 1.5) return 'GPU-bound — blur / gradients / overdraw';
    if (b > r * 1.5) return 'CPU-bound — rebuilds, layout, decoding';
    return 'both threads loaded about equally';
  }

  static double _avg(List<int> xs) {
    if (xs.isEmpty) return 0;
    var sum = 0;
    for (final x in xs) {
      sum += x;
    }
    return sum / xs.length / 1000;
  }

  static double _p90(List<int> xs) {
    if (xs.isEmpty) return 0;
    final sorted = [...xs]..sort();
    // p90 rather than max: one 40 ms frame while a route builds says nothing
    // about what the phone does for the other 200 frames of a scroll.
    final i = ((sorted.length - 1) * 0.9).round();
    return sorted[i] / 1000;
  }
}
