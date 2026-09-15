import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/glass.dart';
import '../../../core/util/debug_log.dart';
import '../../../core/util/transition_probe.dart';

/// One way of opening the chat in a scripted run.
enum BenchVariant {
  /// Whatever the phone is set to.
  asIs,

  /// Panes tinted but not blurred, as the light glass tier draws them.
  noBlur,

  /// The chat's islands each reading the backdrop on their own, as they did
  /// before 1061 — see [AppBlur.groupedPanes].
  ungrouped,
}

/// Opens and closes one conversation from the chat list, the same way every
/// time, in each [BenchVariant] in turn, and files what each cost.
///
/// Hand-tapped logs could not tell builds apart. 1055 and 1057 are the same
/// code and read 8.6 and 5.7 frames over 8.3 ms per chat open — the noise was
/// as large as any change being measured, because a thumb opens the next chat
/// while the last close is still settling, at a different pace every session,
/// on a phone warming up as it goes. Here every open waits the same time, every
/// close does too, and the variants take turns, so heat and battery drift land
/// on all of them.
///
/// The chat list is put underneath first: opened from Diagnostics, the screen
/// being covered would be Diagnostics, which is not the case being asked
/// about. One unmeasured round goes first, so the decoders and caches a first
/// open fills are not charged to any variant.
///
/// While it runs, a sheet over the whole app says so and swallows touches. The
/// first version had neither: it sat on the chat list for a second and a half
/// before its first open, looking like nothing had happened, and on 1058 it
/// was stopped by a touch in that second and a half three times out of three.
/// A touch on the sheet still stops it — now as a choice.
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

  /// Of each variant: three variants at eight rounds is about fifty seconds of
  /// leaving the phone alone, which is roughly as long as anyone will.
  ///
  /// Placeholders and the no-slide variant were in the 1059 run and are not
  /// now: placeholders changed nothing (12-20 frames over 8.3 ms per slide
  /// against 13-15 as it is), and those rounds are better spent on repeats.
  static const int defaultRounds = 8;

  bool _touched = false;

  /// [chat] is a location as [GoRouter.push] takes it. [overlay] is where the
  /// "running" sheet goes: the root one, which outlives the screens the run
  /// moves between.
  Future<void> run({
    required GoRouter router,
    required OverlayState overlay,
    required String chat,
    int rounds = defaultRounds,
  }) async {
    if (running) return;
    final probe = TransitionProbe.instance;
    final wasArmed = probe.armed.value;
    final wasPlaceholders = probe.placeholderMedia.value;
    final wasInstant = probe.instantTransitions.value;
    final wasBlur = AppBlur.panes;
    final wasGrouped = AppBlur.groupedPanes;
    const variants = BenchVariant.values;
    final total = rounds * variants.length;
    progress.value = 'starting';
    _touched = false;
    final sheet = OverlayEntry(builder: (_) => _RunningSheet(bench: this));
    overlay.insert(sheet);
    DebugLog.instance.log(
      'BENCH',
      'start · $rounds opens and closes each of '
          '${variants.map((v) => v.name).join(', ')}, taking turns · '
          'open ${afterOpen.inMilliseconds} ms, '
          'close ${afterClose.inMilliseconds} ms',
    );
    var finished = false;
    void apply(BenchVariant v) {
      AppBlur.panes = v == BenchVariant.noBlur ? false : wasBlur;
      AppBlur.groupedPanes = v == BenchVariant.ungrouped ? false : wasGrouped;
      probe
        ..placeholderMedia.value = false
        ..instantTransitions.value = false;
    }

    try {
      apply(BenchVariant.asIs);
      router.go('/chats');
      await Future<void>.delayed(_settle);
      progress.value = 'warm-up';
      if (!await _cycle(router, chat)) return;

      probe
        ..resetSummary()
        ..scripted = true
        ..arm(true);
      for (var i = 0; i < total; i++) {
        final variant = variants[i % variants.length];
        apply(variant);
        progress.value = '${i + 1}/$total · ${variant.name}';
        if (!await _cycle(router, chat)) return;
      }
      apply(BenchVariant.asIs);
      // Release builds hand frame timings over up to a second late.
      await Future<void>.delayed(_settle);
      probe.logSummary();
      finished = true;
    } finally {
      sheet
        ..remove()
        ..dispose();
      AppBlur.panes = wasBlur;
      AppBlur.groupedPanes = wasGrouped;
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
                '${_touched ? ' — stopped by a touch' : ''}'
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
}

/// Over the whole app while a run goes: what it is doing, and a place for a
/// touch to land that is not a chat.
///
/// Drawn in every measured frame, so it is as little as can say the thing — a
/// dark capsule of text, no blur, no animation — and every variant pays for it
/// alike.
class _RunningSheet extends StatelessWidget {
  const _RunningSheet({required this.bench});

  final TransitionBenchmark bench;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => bench._touched = true,
        child: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xE6000000),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: ValueListenableBuilder<String?>(
                    valueListenable: bench.progress,
                    builder: (context, progress, _) => Text(
                      'scripted run ${progress ?? ''}\n'
                      'hands off · touch to stop',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
