import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../../core/util/debug_log.dart';
import '../../../core/util/transition_probe.dart';

/// Opens and closes one conversation from the chat list, the same way every
/// time, with and without its media, and files what each cost.
///
/// Hand-tapped logs could not tell builds apart. 1055 and 1057 are the same
/// code and read 8.6 and 5.7 frames over 8.3 ms per chat open — the noise was
/// as large as any change being measured, because a thumb opens the next chat
/// while the last close is still settling, at a different pace every session,
/// on a phone warming up as it goes. Here every open waits the same time, every
/// close does too, and the two variants alternate, so heat and battery drift
/// land on both.
///
/// The chat list is put underneath first: opened from Diagnostics, the screen
/// being covered would be Diagnostics, which is not the case being asked
/// about. One unmeasured round goes first, so the decoders and caches a first
/// open fills are not charged to either variant.
///
/// A touch stops it, and so does leaving the app. Either would put
/// transitions in the log that the script did not make.
class TransitionBenchmark {
  TransitionBenchmark._();

  static final TransitionBenchmark instance = TransitionBenchmark._();

  /// Null while idle; otherwise how far it has got.
  final ValueNotifier<String?> progress = ValueNotifier<String?>(null);

  bool get running => progress.value != null;

  /// Long enough for the open's 450 ms window and the frames after it.
  static const Duration afterOpen = Duration(milliseconds: 900);

  /// The close's 520 ms window, and the chat list catching up after it.
  static const Duration afterClose = Duration(milliseconds: 1100);

  static const Duration _settle = Duration(milliseconds: 1500);

  /// Of each variant. Ten of each is about 45 seconds of leaving the phone
  /// alone, which is roughly as long as anyone will.
  static const int defaultRounds = 10;

  bool _touched = false;

  /// [chat] is a location as [GoRouter.push] takes it; [rounds] of each
  /// variant.
  Future<void> run({
    required GoRouter router,
    required String chat,
    int rounds = defaultRounds,
  }) async {
    if (running) return;
    final probe = TransitionProbe.instance;
    final wasArmed = probe.armed.value;
    final wasPlaceholders = probe.placeholderMedia.value;
    final wasInstant = probe.instantTransitions.value;
    progress.value = 'starting';
    _touched = false;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    DebugLog.instance.log(
      'BENCH',
      'start · $rounds opens and closes each, normal and placeholders '
          'alternating · open ${afterOpen.inMilliseconds} ms, '
          'close ${afterClose.inMilliseconds} ms',
    );
    var finished = false;
    try {
      probe
        ..instantTransitions.value = false
        ..placeholderMedia.value = false;
      router.go('/chats');
      await Future<void>.delayed(_settle);
      progress.value = 'warm-up';
      if (!await _cycle(router, chat)) return;

      probe
        ..resetSummary()
        ..scripted = true
        ..arm(true);
      final total = rounds * 2;
      for (var i = 0; i < total; i++) {
        probe.placeholderMedia.value = i.isOdd;
        progress.value = '${i + 1}/$total';
        if (!await _cycle(router, chat)) return;
      }
      // Release builds hand frame timings over up to a second late.
      await Future<void>.delayed(_settle);
      probe.logSummary();
      finished = true;
    } finally {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
      probe
        ..scripted = false
        ..placeholderMedia.value = wasPlaceholders
        ..instantTransitions.value = wasInstant;
      if (!wasArmed) probe.arm(false);
      DebugLog.instance.log(
        'BENCH',
        finished
            ? 'done'
            : 'stopped at ${progress.value}'
                '${_touched ? ' — the screen was touched' : ''}'
                '${_foreground ? '' : ' — the app left the screen'}',
      );
      progress.value = null;
      if (_foreground) unawaited(router.push<void>('/diagnostics'));
    }
  }

  Future<bool> _cycle(GoRouter router, String chat) async {
    if (_interrupted) return false;
    unawaited(router.push<void>(chat));
    await Future<void>.delayed(afterOpen);
    if (_interrupted || !router.canPop()) return false;
    router.pop();
    await Future<void>.delayed(afterClose);
    return !_interrupted;
  }

  bool get _interrupted => _touched || !_foreground;

  static bool get _foreground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent) _touched = true;
  }
}
