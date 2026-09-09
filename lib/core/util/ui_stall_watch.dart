import 'dart:async';

import 'package:flutter/widgets.dart';

import 'debug_log.dart';

/// Notices when the UI thread stopped answering.
///
/// **Why this exists beside [FrameStats], which already measures frames.** It
/// measures the frames that happen. A thread blocked inside a synchronous call
/// produces no frames at all, so no timing callback fires, so the slow-frame
/// reporter has nothing to report and the panel's averages stay excellent. The
/// worse the stall, the less the frame meter sees of it — which is exactly
/// backwards, and it is why a report of "the screen freezes half way through
/// going back" arrived alongside a log showing two slow frames in twelve
/// minutes. Both were true.
///
/// A timer measures its own lateness instead. Nothing else on the event loop
/// can run while it is blocked, so a tick scheduled for 500 ms that arrives at
/// 1400 ms says the loop was held for about 900 ms, whatever held it. That is
/// the one number the frame meter cannot produce.
///
/// It cannot say *what* blocked, only for how long and when — and "when" is the
/// point, because [DebugLog] timestamps every line, so the stall lands among
/// the `[NAV]`, `[CHAT]` and `[NOSTR]` lines written on either side of it.
class UiStallWatch with WidgetsBindingObserver {
  UiStallWatch._();
  static final UiStallWatch instance = UiStallWatch._();

  /// How often the loop is asked whether it is still there.
  ///
  /// Half a second: a timer that has to fire is a frame's worth of nothing, and
  /// at this cadence the cost is unmeasurable next to a presence beacon. Any
  /// faster buys resolution on stalls that are already too short to see.
  static const Duration _tick = Duration(milliseconds: 500);

  /// Lateness worth a line.
  ///
  /// 250 ms rather than a frame budget. This is not a jank detector — that is
  /// [FrameStats], which is better at it — it is for the class of pause a
  /// person calls a freeze, and nobody calls 40 ms anything.
  static const Duration _report = Duration(milliseconds: 250);

  Timer? _timer;
  DateTime? _due;
  bool _foreground = true;

  /// Start watching. Safe to call twice; the second call does nothing.
  void install() {
    if (_timer != null) return;
    WidgetsBinding.instance.addObserver(this);
    _schedule();
  }

  void _schedule() {
    _due = DateTime.now().add(_tick);
    _timer = Timer(_tick, _fire);
  }

  void _fire() {
    final due = _due;
    final late = due == null ? Duration.zero : DateTime.now().difference(due);
    // Only in the foreground, and never across a resume. A backgrounded app has
    // its timers throttled by the platform by design, so every return from the
    // background would otherwise report a stall of however long the phone was
    // in a pocket — a meter that cries loudest when nothing is wrong is a meter
    // people learn to ignore.
    if (_foreground && late > _report) {
      DebugLog.instance.log(
        'STALL',
        'UI thread did not answer for ${late.inMilliseconds} ms',
      );
    }
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasForeground = _foreground;
    _foreground = state == AppLifecycleState.resumed;
    // The tick that spans the return is the throttled one, so it is skipped by
    // restarting the clock rather than by trusting the state at report time.
    if (_foreground && !wasForeground) {
      _timer?.cancel();
      _schedule();
    }
  }

  /// For tests, and for a wipe that tears everything down.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _due = null;
    WidgetsBinding.instance.removeObserver(this);
  }
}
