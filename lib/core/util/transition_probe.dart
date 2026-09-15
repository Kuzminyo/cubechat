import 'dart:async';
import 'dart:io' show ProcessInfo;
import 'dart:math' as math;
import 'dart:ui' show FramePhase, FrameTiming, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../theme/glass.dart';
import 'debug_log.dart';

/// What one screen transition cost, frame by frame, from a release build.
///
/// "Opening and closing a chat jerks" is a report about roughly twenty frames,
/// and the panels this app already had could not look at twenty frames: the
/// frame meter keeps a rolling window of 180 and logs one slow frame a second,
/// so a transition showed up as a single `[FRAME]` line of whichever frame was
/// worst, with no count, no duration and nothing to compare the next attempt
/// against. Flutter DevTools answers the question properly, but only on a
/// profile build with the phone on a cable, and this repo has no phone attached
/// to the machine that builds it.
///
/// So the phone measures itself. While armed from Diagnostics, every route
/// push and pop opens a window of frames, keyed by the engine's own frame
/// number so the timings - which a release build hands over in batches up to a
/// second late - land on the transition they belong to. Each window becomes one
/// `[NAV-COST]` line, and the Diagnostics card keeps a per-scenario summary so
/// ten opens of the same chat read as one row.
///
/// A window is a fixed length of wall time rather than "until the animation
/// ends", so a transition measured with the animation switched off (see
/// [instantTransitions]) covers the same stretch and the two can be compared.
///
/// Off unless armed: the timings callback is registered only then, and the
/// engine stops recording timings for a process that has no callback.
class TransitionProbe {
  TransitionProbe._();

  static final TransitionProbe instance = TransitionProbe._();

  /// Measuring. Not saved: a diagnostic that survived a restart would be a
  /// cost somebody forgot they turned on.
  final ValueNotifier<bool> armed = ValueNotifier<bool>(false);

  /// **Experiment, temporary.** Routes appear and leave without sliding. For
  /// comparing the same open with and without the animation, never a setting.
  final ValueNotifier<bool> instantTransitions = ValueNotifier<bool>(false);

  /// **Experiment, temporary.** Photos, clips and circles in a conversation
  /// draw a flat box instead of decoding anything. Read when a bubble is
  /// built, so it applies to the next chat opened.
  final ValueNotifier<bool> placeholderMedia = ValueNotifier<bool>(false);

  /// **Experiment, temporary.** A pushed screen is not opaque, so the one under
  /// it goes on being painted the whole time it is covered.
  ///
  /// 1062's scripted run put every slow frame of a chat close in its first
  /// 90 ms — `+0:b10 +16:r20 +24:r14 +41:r14 … +83:r9` — with the blur on
  /// or off alike, and none after. That is the moment the chat list, not
  /// painted at all while the conversation covered it, has to be recorded and
  /// drawn again from nothing. Keeping it painted is the one change that
  /// answers whether that is the cost; it costs GPU for every frame drawn in
  /// the open chat, which the same run measures.
  final ValueNotifier<bool> keepUnderlay = ValueNotifier<bool>(false);

  /// The transitions are being driven by a script rather than a thumb — see
  /// `TransitionBenchmark`. Filed apart, because the two are not comparable:
  /// a thumb opens the next chat while the last close is still settling.
  bool scripted = false;

  /// Bumped whenever [summary] changes.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static const Duration _openWindow = Duration(milliseconds: 450);
  static const Duration _closeWindow = Duration(milliseconds: 520);
  static const Duration _resumeWindow = Duration(milliseconds: 1500);

  /// A window whose frames never all arrive is closed with what it has.
  static const Duration _giveUpAfter = Duration(seconds: 4);

  final Stopwatch _clock = Stopwatch()..start();
  final Expando<_RouteNote> _notes = Expando<_RouteNote>('transition note');
  final Set<String> _openedKeys = <String>{};
  final List<_Window> _windows = <_Window>[];
  final Map<String, _Scenario> _scenarios = <String, _Scenario>{};

  void arm(bool on) {
    if (armed.value == on) return;
    armed.value = on;
    if (on) {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
    } else {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      for (final w in _windows) {
        w.giveUp?.cancel();
        w.close?.cancel();
      }
      _windows.clear();
    }
  }

  /// A screen says what it is, so its transitions are filed under a name that
  /// means something. [key] tells a first open from a repeat and never leaves
  /// the phone; [label] goes into the log, so it must not carry an id.
  ///
  /// [label] is only asked for once per route, so it may walk a conversation.
  void describe(
    BuildContext context, {
    required String key,
    required String Function() label,
  }) {
    if (!armed.value) return;
    final route = ModalRoute.of(context);
    if (route == null || _notes[route] != null) return;
    _notes[route] = _RouteNote(label: label(), key: key);
  }

  /// A route was pushed ([opening]) or popped.
  void noteRoute(Route<dynamic> route, {required bool opening}) {
    if (opening) _lastOpened = route;
    if (!armed.value) return;
    _open(
      kind: opening ? 'open' : 'close',
      route: route,
      length: opening ? _openWindow : _closeWindow,
    );
  }

  /// The screen opened last, so a scroll through it is filed under its name.
  Route<dynamic>? _lastOpened;

  static const Duration _scrollWindow = Duration(milliseconds: 1200);

  /// A scroll of the screen on top, driven by `TransitionBenchmark`, is about
  /// to start: the frames of the drag and the fling after it.
  ///
  /// Asked for because a change that fixes a transition can cost every frame
  /// drawn in between — keeping the chat list painted under a conversation is
  /// the case that raised it — and a scroll is the most frames anyone draws in
  /// a chat.
  void noteScroll() {
    if (!armed.value) return;
    _open(kind: 'scroll', route: _lastOpened, length: _scrollWindow);
  }

  /// The app came back to the front: resuming is measured on its own, so a
  /// chat opened straight after is not blamed for it.
  void noteResume() {
    if (!armed.value) return;
    _open(kind: 'resume', route: null, length: _resumeWindow);
  }

  void _open({
    required String kind,
    required Route<dynamic>? route,
    required Duration length,
  }) {
    final window = _Window(
      kind: kind,
      route: route,
      fromFrame: windowStart(
        PlatformDispatcher.instance.frameData.frameNumber,
        SchedulerBinding.instance.schedulerPhase,
      ),
      startedMs: _clock.elapsedMilliseconds,
      experiments: _experiments(),
    );
    _windows.add(window);
    // Frames keep being drawn for a moment after the animation ends, and the
    // one after the last slide is often the expensive one - it is when the
    // screen underneath is put back.
    window.close = Timer(length, () {
      window.toFrame = PlatformDispatcher.instance.frameData.frameNumber;
      _finishIfComplete(window);
    });
    window.giveUp = Timer(length + _giveUpAfter, () => _finish(window));
  }

  /// The last frame number *not* in a window opened at [current] during
  /// [phase].
  ///
  /// **A push made by the router lands inside a frame, not between two.**
  /// `context.push` only tells the router; the Navigator receives its new page
  /// list while that frame builds, calls `didPush` from inside the build, and
  /// builds the chat in the same frame. So the frame number read in `didPush`
  /// is the number of the very frame that builds the chat - and counting from
  /// the one after it left out the heaviest frame of every open. The 1052 log
  /// shows it: `open chat` windows with a build max of 1.7 ms beside a
  /// `[FRAME]` line of 24-34 ms `chat, chats`, and that frame turning up in
  /// the *previous* chat's close window whenever the next chat was opened
  /// within its 520 ms. A push from a tap between frames (idle, or after the
  /// frame's callbacks) still starts with the next frame.
  @visibleForTesting
  static int windowStart(int current, SchedulerPhase phase) =>
      phase == SchedulerPhase.idle || phase == SchedulerPhase.postFrameCallbacks
          ? current
          : current - 1;

  String _experiments() => [
        if (scripted) 'bench',
        if (instantTransitions.value) 'instant',
        if (placeholderMedia.value) 'placeholders',
        if (keepUnderlay.value) 'underlay',
        AppBlur.panes ? 'blur' : 'no-blur',
        if (AppBlur.panes && !AppBlur.groupedPanes) 'ungrouped',
      ].join(',');

  void _onTimings(List<FrameTiming> timings) {
    if (_windows.isEmpty) return;
    for (final t in timings) {
      final n = t.frameNumber;
      if (n < 0) continue;
      for (final w in _windows) {
        if (n <= w.fromFrame) continue;
        final to = w.toFrame;
        if (to != null && n > to) continue;
        w.frames[n] = t;
      }
    }
    for (final w in List<_Window>.of(_windows)) {
      _finishIfComplete(w);
    }
  }

  void _finishIfComplete(_Window w) {
    final to = w.toFrame;
    if (to == null) return;
    // Every frame up to the end has reported, or there were none to report.
    final newest = w.frames.keys.fold<int>(w.fromFrame, math.max);
    if (newest >= to) _finish(w);
  }

  void _finish(_Window w) {
    if (!_windows.remove(w)) return;
    w.close?.cancel();
    w.giveUp?.cancel();
    final note = w.route == null ? null : _notes[w.route!];
    final label = w.kind == 'resume'
        ? 'app'
        : note?.label ?? _routeName(w.route);
    final first = w.kind == 'open' && note != null && _openedKeys.add(note.key);
    final frames = w.frames.values.toList();
    final report = TransitionReport.of(
      kind: w.kind,
      label: label,
      first: first,
      experiments: w.experiments,
      frames: frames,
      rssBytes: _rss(),
    );
    DebugLog.instance.log('NAV-COST', report.line);
    final scenario = _scenarios.putIfAbsent(report.scenario, _Scenario.new);
    scenario.add(report, frames);
    revision.value++;
  }

  static int? _rss() {
    try {
      return ProcessInfo.currentRss;
    } catch (_) {
      return null;
    }
  }

  static String _routeName(Route<dynamic>? route) {
    final name = route?.settings.name;
    if (name != null && name.isNotEmpty) return name;
    return 'screen';
  }

  /// One row per scenario, in the order they were first seen.
  List<ScenarioSummary> get summary => [
        for (final entry in _scenarios.entries)
          entry.value.summarise(entry.key),
      ];

  void resetSummary() {
    _scenarios.clear();
    _openedKeys.clear();
    revision.value++;
  }

  /// The summary into the log, so it leaves the phone with the shared file.
  void logSummary() {
    final rows = summary;
    if (rows.isEmpty) {
      DebugLog.instance.log('NAV-COST', 'summary: nothing measured yet');
      return;
    }
    for (final row in rows) {
      DebugLog.instance.log('NAV-COST', 'summary · ${row.line}');
    }
  }

  @visibleForTesting
  void ingestForTest(List<FrameTiming> timings) => _onTimings(timings);
}

class _RouteNote {
  const _RouteNote({required this.label, required this.key});
  final String label;
  final String key;
}

class _Window {
  _Window({
    required this.kind,
    required this.route,
    required this.fromFrame,
    required this.startedMs,
    required this.experiments,
  });

  final String kind;
  final Route<dynamic>? route;
  final int fromFrame;
  final int startedMs;
  final String experiments;
  int? toFrame;
  Timer? close;
  Timer? giveUp;
  final Map<int, FrameTiming> frames = <int, FrameTiming>{};
}

/// One transition, in numbers.
@immutable
class TransitionReport {
  const TransitionReport({
    required this.kind,
    required this.label,
    required this.first,
    required this.experiments,
    required this.frameCount,
    required this.buildP95,
    required this.buildP99,
    required this.buildMax,
    required this.rasterP95,
    required this.rasterP99,
    required this.rasterMax,
    required this.over8,
    required this.over16,
    required this.spanMs,
    required this.rssBytes,
    this.slow = const [],
  });

  factory TransitionReport.of({
    required String kind,
    required String label,
    required bool first,
    required String experiments,
    required List<FrameTiming> frames,
    required int? rssBytes,
  }) {
    final build = [for (final f in frames) f.buildDuration.inMicroseconds];
    final raster = [for (final f in frames) f.rasterDuration.inMicroseconds];
    var over8 = 0;
    var over16 = 0;
    var spanUs = 0;
    final sorted = [...frames]
      ..sort((a, b) => a.frameNumber.compareTo(b.frameNumber));
    final startUs = sorted.isEmpty
        ? 0
        : sorted.first.timestampInMicroseconds(FramePhase.vsyncStart);
    final slow = <SlowFrame>[
      for (final f in sorted)
        if (math.max(
              f.buildDuration.inMicroseconds,
              f.rasterDuration.inMicroseconds,
            ) >
            8333)
          SlowFrame(
            atMs: (f.timestampInMicroseconds(FramePhase.vsyncStart) - startUs) ~/
                1000,
            buildMs: f.buildDuration.inMicroseconds / 1000,
            rasterMs: f.rasterDuration.inMicroseconds / 1000,
          ),
    ];
    for (final f in frames) {
      // Late by the thread that was late: a frame is over budget when either
      // side of it is, which is how the meter above counts too.
      final worst = math.max(
        f.buildDuration.inMicroseconds,
        f.rasterDuration.inMicroseconds,
      );
      if (worst > 8333) over8++;
      if (worst > 16667) over16++;
    }
    if (sorted.length > 1) {
      spanUs = sorted.last.timestampInMicroseconds(FramePhase.rasterFinish) -
          startUs;
    }
    return TransitionReport(
      kind: kind,
      label: label,
      first: first,
      experiments: experiments,
      frameCount: frames.length,
      buildP95: percentileMs(build, 0.95),
      buildP99: percentileMs(build, 0.99),
      buildMax: percentileMs(build, 1),
      rasterP95: percentileMs(raster, 0.95),
      rasterP99: percentileMs(raster, 0.99),
      rasterMax: percentileMs(raster, 1),
      over8: over8,
      over16: over16,
      spanMs: spanUs ~/ 1000,
      rssBytes: rssBytes,
      slow: slow,
    );
  }

  final String kind;
  final String label;
  final bool first;
  final String experiments;
  final int frameCount;
  final double buildP95;
  final double buildP99;
  final double buildMax;
  final double rasterP95;
  final double rasterP99;
  final double rasterMax;
  final int over8;
  final int over16;

  /// From the first frame's vsync to the last frame's raster.
  final int spanMs;
  final int? rssBytes;

  /// The frames over 8.3 ms, and how far into the window each one began.
  ///
  /// Totals could not say *where* a transition hurts. Closing a chat read
  /// about six frames over budget with the blur on, off or grouped alike
  /// (1061), which is a second cause — and whether it is the first frame of
  /// the slide, its middle or the frame after it lands decides which one.
  final List<SlowFrame> slow;

  /// What ten attempts of the same thing are filed under.
  String get scenario =>
      '$kind $label${first ? ' (first)' : ''} [$experiments]';

  String get line => '$scenario · $spanMs ms · $frameCount frames'
      ' · build p95 ${_ms(buildP95)} p99 ${_ms(buildP99)} max ${_ms(buildMax)}'
      ' · raster p95 ${_ms(rasterP95)} p99 ${_ms(rasterP99)} max ${_ms(rasterMax)}'
      ' · >8.3 ms: $over8 · >16.7 ms: $over16'
      '${rssBytes == null ? '' : ' · rss ${rssBytes! ~/ (1024 * 1024)} MB'}'
      // Scripted runs only: a hand-tapped line is long enough, and nobody
      // reads a hundred of them frame by frame.
      '${experiments.contains('bench') && slow.isNotEmpty ? ' · slow ${slow.join(' ')}' : ''}';

  static String _ms(double v) => v.toStringAsFixed(1);

  /// Nearest-rank percentile of microsecond samples, in milliseconds.
  @visibleForTesting
  static double percentileMs(List<int> samples, double p) {
    if (samples.isEmpty) return 0;
    final sorted = [...samples]..sort();
    final rank = (p * sorted.length).ceil().clamp(1, sorted.length);
    return sorted[rank - 1] / 1000;
  }
}

/// A frame over budget inside a transition window.
@immutable
class SlowFrame {
  const SlowFrame({
    required this.atMs,
    required this.buildMs,
    required this.rasterMs,
  });

  /// From the window's first frame to this one's vsync.
  final int atMs;
  final double buildMs;
  final double rasterMs;

  /// `+120:r13` — when, and which thread was late by how much.
  @override
  String toString() => buildMs >= rasterMs
      ? '+$atMs:b${buildMs.round()}'
      : '+$atMs:r${rasterMs.round()}';
}

class _Scenario {
  final List<TransitionReport> reports = <TransitionReport>[];
  final List<int> build = <int>[];
  final List<int> raster = <int>[];

  /// Frames over budget per 100 ms of the window, summed over the runs; the
  /// last bucket takes everything from 500 ms on.
  final List<int> slowByTenth = List<int>.filled(6, 0);

  void add(TransitionReport report, List<FrameTiming> frames) {
    reports.add(report);
    for (final s in report.slow) {
      slowByTenth[math.min(s.atMs ~/ 100, slowByTenth.length - 1)]++;
    }
    for (final f in frames) {
      build.add(f.buildDuration.inMicroseconds);
      raster.add(f.rasterDuration.inMicroseconds);
    }
  }

  ScenarioSummary summarise(String name) {
    final spans = [for (final r in reports) r.spanMs]..sort();
    final rss = [for (final r in reports) if (r.rssBytes != null) r.rssBytes!];
    return ScenarioSummary(
      name: name,
      runs: reports.length,
      medianSpanMs: spans.isEmpty ? 0 : spans[spans.length ~/ 2],
      buildP95: TransitionReport.percentileMs(build, 0.95),
      buildP99: TransitionReport.percentileMs(build, 0.99),
      rasterP95: TransitionReport.percentileMs(raster, 0.95),
      rasterP99: TransitionReport.percentileMs(raster, 0.99),
      over8PerRun: reports.isEmpty
          ? 0
          : reports.fold<int>(0, (a, r) => a + r.over8) / reports.length,
      over16PerRun: reports.isEmpty
          ? 0
          : reports.fold<int>(0, (a, r) => a + r.over16) / reports.length,
      rssFirstMb: rss.isEmpty ? null : rss.first ~/ (1024 * 1024),
      rssLastMb: rss.isEmpty ? null : rss.last ~/ (1024 * 1024),
      slowByTenthPerRun: reports.isEmpty
          ? const []
          : [for (final n in slowByTenth) n / reports.length],
    );
  }
}

/// Ten attempts at one scenario, as one row.
@immutable
class ScenarioSummary {
  const ScenarioSummary({
    required this.name,
    required this.runs,
    required this.medianSpanMs,
    required this.buildP95,
    required this.buildP99,
    required this.rasterP95,
    required this.rasterP99,
    required this.over8PerRun,
    required this.over16PerRun,
    required this.rssFirstMb,
    required this.rssLastMb,
    this.slowByTenthPerRun = const [],
  });

  final String name;
  final int runs;
  final int medianSpanMs;
  final double buildP95;
  final double buildP99;
  final double rasterP95;
  final double rasterP99;
  final double over8PerRun;
  final double over16PerRun;
  final int? rssFirstMb;
  final int? rssLastMb;

  /// Frames over 8.3 ms per run in each 100 ms of the window: 0-99, 100-199,
  /// … and 500 on. Where in a transition the cost lands.
  final List<double> slowByTenthPerRun;

  String get line => '$name × $runs · median $medianSpanMs ms'
      ' · build p95 ${buildP95.toStringAsFixed(1)} p99 ${buildP99.toStringAsFixed(1)}'
      ' · raster p95 ${rasterP95.toStringAsFixed(1)} p99 ${rasterP99.toStringAsFixed(1)}'
      ' · per run >8.3: ${over8PerRun.toStringAsFixed(1)}'
      ' >16.7: ${over16PerRun.toStringAsFixed(1)}'
      '${rssFirstMb == null ? '' : ' · rss $rssFirstMb→$rssLastMb MB'}'
      '${slowByTenthPerRun.isEmpty ? '' : ' · slow per 100 ms ${slowByTenthPerRun.map((n) => n.toStringAsFixed(1)).join('/')}'}';
}
