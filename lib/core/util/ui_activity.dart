import 'dart:async';

import 'package:flutter/foundation.dart';

/// App-wide "is anything actually happening" signal, for decorative animations
/// that would otherwise run forever.
///
/// The aurora backdrop already parks itself a couple of seconds after the last
/// touch, and that was the single biggest win of the earlier idle pass. But the
/// online dot on every avatar kept pulsing regardless — that pass made each
/// tick *cheaper* (an opacity fade instead of re-rasterising a blur) without
/// stopping the ticking. A ticker running is a frame scheduled, so with even
/// one online peer on screen the app never reaches a still frame, and on a
/// ProMotion display that means compositing at 120 Hz indefinitely while the
/// user just reads.
///
/// One shared signal rather than a timer per dot: a chat list can hold a dozen
/// of them, and a dozen independent idle timers is the sort of thing this is
/// supposed to be removing.
///
/// Deliberately *not* wired to app lifecycle — Flutter already stops scheduling
/// frames when the app is not visible, so tickers pause on their own there.
/// This is about the foreground, where the drain actually happens.
class UiActivity {
  UiActivity._();
  static final UiActivity instance = UiActivity._();

  /// How long after the last touch the interface is considered at rest.
  ///
  /// Generous on purpose: someone reading a conversation without touching it is
  /// still looking at it, and a pulse that dies the instant a finger lifts
  /// reads as a glitch rather than as calm.
  static const Duration _quietAfter = Duration(seconds: 4);

  /// True while nothing has been touched for [_quietAfter]. Decorative
  /// animations should park themselves while this is true.
  final ValueNotifier<bool> isQuiet = ValueNotifier<bool>(false);

  Timer? _timer;

  /// Suppresses the countdown, leaving the interface permanently "in use".
  ///
  /// Set by `test/flutter_test_config.dart` for the whole suite. Every widget
  /// test that taps or drags would otherwise arm this timer through the root
  /// pointer listener, and `testWidgets` fails a test that ends with a timer
  /// still pending — a global singleton holding a four-second countdown is
  /// exactly the kind of thing that leaks into unrelated tests. Leaving the
  /// signal "loud" is the safe direction: animations simply keep running, which
  /// is what tests saw before this existed.
  @visibleForTesting
  static bool debugDisableQuietTimer = false;

  /// Report user activity. Cheap enough to call from a pointer callback: it
  /// only re-arms a timer, and only notifies listeners on an actual transition.
  void poke() {
    if (isQuiet.value) isQuiet.value = false;
    if (debugDisableQuietTimer) return;
    _timer?.cancel();
    _timer = Timer(_quietAfter, () => isQuiet.value = true);
  }

  @visibleForTesting
  void resetForTest() {
    _timer?.cancel();
    _timer = null;
    isQuiet.value = false;
  }
}
