import 'dart:async';
import 'dart:ui' show FrameTiming;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/scheduler.dart';

import 'debug_log.dart';

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

  /// Frames long enough to be *seen* as a stop rather than a stutter.
  ///
  /// The counts above answer "how often is a frame late", which is the wrong
  /// question for "подфризує". A hundred frames at 20 ms is a soft, even
  /// slowness nobody names; one frame at 250 ms is a freeze, and it moves
  /// neither the average nor the p90 of a 180-frame window at all. Reported
  /// separately, with the worst frame beside it, so the two failures can be
  /// told apart instead of both hiding behind a healthy percentile.
  int _stalls = 0;
  int _worstBuildUs = 0;
  int _worstRasterUs = 0;

  /// Where a late frame stops being a stutter and starts being a stop. 100 ms
  /// is roughly the threshold at which a pause reads as the app having hung
  /// rather than having slowed.
  static const int _stallUs = 100000;

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
    _closeFrames();
  }

  /// Close off each frame's build counts as that frame finishes.
  ///
  /// A persistent frame callback runs inside `handleDrawFrame`, and
  /// `WidgetsBinding` registered its own `drawFrame` before this one — so by
  /// the time this runs, build, layout and paint for the frame are done and
  /// [_buildCounts] holds exactly what that frame rebuilt. Moving it aside here
  /// is what turns "seventeen chats builds somewhere in the last second" into
  /// "this 25 ms frame rebuilt chats once".
  ///
  /// Registered once and never removed: a persistent callback cannot be, and
  /// the work is moving a map of at most a handful of entries.
  void _closeFrames() {
    if (_closingFrames) return;
    _closingFrames = true;
    SchedulerBinding.instance.addPersistentFrameCallback((_) {
      if (_buildCounts.isEmpty) {
        // Still a frame, and still needs an entry: the queue below is matched
        // to the timings stream position by position, so a frame that skipped
        // is a frame that has to be represented.
        _frameCounts.add(const <String, int>{});
      } else {
        _frameCounts.add(Map<String, int>.of(_buildCounts));
        _buildCounts.clear();
      }
      // Timings arrive a frame or two behind, never further, so a short queue
      // is enough — and a bounded one cannot grow while nobody is listening.
      while (_frameCounts.length > _frameCountsDepth) {
        _frameCounts.removeAt(0);
      }
    });
  }

  bool _closingFrames = false;

  /// Per-frame build counts, oldest first, waiting for their timing.
  ///
  /// Paired with the timings stream by position rather than by a frame number:
  /// every drawn frame pushes exactly one entry here and produces exactly one
  /// [FrameTiming], and both arrive in order. If the two ever slip, the counts
  /// are off by a frame — which is still an incomparably better answer than the
  /// one-second window this replaced.
  final List<Map<String, int>> _frameCounts = <Map<String, int>>[];
  static const int _frameCountsDepth = 8;

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
    _stalls = 0;
    _worstBuildUs = 0;
    _worstRasterUs = 0;
    // Both belong to the window that just ended. Left behind, the rate limit
    // could swallow the first slow frame after a reset — the one somebody
    // pressed reset in order to see.
    _lastReport = null;
    _frameCounts.clear();
    _lastSlowFrameWho = null;
  }

  /// What the last reported slow frame said rebuilt, for tests.
  ///
  /// The log is the real output, and in a test it is not reachable: [DebugLog]
  /// captures `debugPrint`, which `flutter_test` has already replaced with its
  /// own. Asserting on this instead keeps the test about the thing worth
  /// pinning down — that a frame is blamed for its own rebuilds and not for
  /// the ones around it.
  @visibleForTesting
  String? get lastSlowFrameWho => _lastSlowFrameWho;
  String? _lastSlowFrameWho;

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
      if (build > _stallUs || raster > _stallUs) _stalls++;
      if (build > _worstBuildUs) _worstBuildUs = build;
      if (raster > _worstRasterUs) _worstRasterUs = raster;
      _framesSinceReport++;
      // Taken for every frame, slow or not, so the queue stays in step with the
      // timings rather than draining only when something is reported.
      final who = _frameCounts.isEmpty
          ? const <String, int>{}
          : _frameCounts.removeAt(0);
      _reportIfSlow(build, raster, who);
      if (_buildUs.length > _window) _buildUs.removeAt(0);
      if (_rasterUs.length > _window) _rasterUs.removeAt(0);
    }
  }

  /// Put a slow frame into the log, next to whatever caused it.
  ///
  /// The panel says a session's worst frame was 33 ms of build and says nothing
  /// about *when*. That was enough to prove the first-open stall was on the
  /// Dart thread and not the GPU, and not enough to survive the next step: a
  /// change reasoned from that number moved it by 3 ms, which is noise, and
  /// there was no way to tell whether the theory was wrong or the fix was
  /// aimed at the wrong frame.
  ///
  /// DebugLog already timestamps every line to the millisecond, so a frame
  /// reported here lands directly among the `[CHAT]`, `[NOSTR]` and `[CRYPTO]`
  /// lines written while it was being built. That turns "something took 33 ms"
  /// into a list of what was running at the time, which is the question.
  ///
  /// Rate-limited to one a second. A phone that starts dropping frames drops
  /// a lot of them, and a 200-line buffer that fills with its own reporting is
  /// a buffer that has evicted the evidence.
  void _reportIfSlow(int buildUs, int rasterUs, Map<String, int> thisFrame) {
    if (buildUs < _reportUs && rasterUs < _reportUs) return;
    final now = DateTime.now();
    final last = _lastReport;
    if (last != null && now.difference(last) < const Duration(seconds: 1)) {
      return;
    }
    final since = _framesSinceReport;
    _framesSinceReport = 0;
    _lastReport = now;
    // What *this* frame rebuilt, not what the last second did. The window
    // version could not tell a suspect from a bystander: "chats x17" beside a
    // 25 ms frame is either the whole story or seventeen cheap rebuilds spread
    // over two hundred other frames, and there was no way to know which.
    final who = _format(thisFrame);
    _lastSlowFrameWho = who;
    DebugLog.instance.log(
      'FRAME',
      'slow frame — build ${(buildUs / 1000).toStringAsFixed(1)} ms, '
          'raster ${(rasterUs / 1000).toStringAsFixed(1)} ms'
          ' — ${who.isEmpty ? 'nothing counted rebuilt' : who}'
          ' · 1 of $since frame(s) since the last report',
    );
  }

  static String _format(Map<String, int> counts) {
    if (counts.isEmpty) return '';
    final rows = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return rows.map((e) => '${e.key} x${e.value}').join(', ');
  }

  /// Frames covered by the counts in the line above.
  ///
  /// Without it `chats x2` is unreadable: two rebuilds across sixty frames is
  /// nothing, and two across three frames is the whole story. The first log to
  /// carry the counts read `chats x2` beside a 35 ms build, which is either a
  /// vindication or a red herring depending on this number, and there was no
  /// way to tell which.
  int _framesSinceReport = 0;

  /// How many times each watched screen rebuilt since the last report.
  ///
  /// The first instrumentation round proved the stall was on the Dart thread
  /// and ruled out the two calls that looked expensive — both came back at
  /// 0.0 ms of synchronous work. What it could not say is *which tree* was
  /// being rebuilt, and the honest answer to that is not visible in the source:
  /// the tab shell keeps every branch mounted, so a screen nobody is looking
  /// at rebuilds on every provider change and pays for it in full.
  ///
  /// So the screens count themselves. A slow frame arrives with a list of who
  /// rebuilt beside it, which is the difference between a suspect and a name.
  ///
  /// Counting is one increment on an int — cheap enough to leave in an ordinary
  /// build, which matters because the stall being chased does not reproduce on
  /// demand.
  static void countBuild(String screen) {
    _buildCounts[screen] = (_buildCounts[screen] ?? 0) + 1;
  }

  /// This frame's counts so far, emptied into [_frameCounts] when it ends.
  static final Map<String, int> _buildCounts = <String, int>{};

  /// One 60 Hz frame.
  ///
  /// It was two, and that was set while thinking in 60 Hz. On the phone doing
  /// the reporting the display runs at 120, where the budget is 8.3 ms — so a
  /// frame of 25 ms is three dropped in a row, plainly visible, and sat
  /// silently under a 33 ms threshold. A log came back covering three chat
  /// opens and two closes with no `[FRAME]` line in it at all, while the person
  /// holding the phone could see the stutter. The meter was wrong, not them.
  ///
  /// Flooding is handled by the once-a-second limit below rather than by the
  /// threshold, which is what lets this be low enough to be useful.
  static const int _reportUs = 16700;

  DateTime? _lastReport;

  bool get hasSamples => _buildUs.isNotEmpty;
  int get sampleCount => _buildUs.length;
  int get totalFrames => _total;
  int get jankyFrames => _janky;

  /// Frames past [_stallUs] — the ones felt as a freeze. Cumulative for the
  /// session, like [jankyFrames], because a stall three minutes ago is exactly
  /// the thing being reported.
  int get stallFrames => _stalls;

  /// The single worst frame of the session, per thread. One number, and the
  /// one that says whether a "freeze" is real.
  double get worstBuildMs => _worstBuildUs / 1000;
  double get worstRasterMs => _worstRasterUs / 1000;

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
