import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// How many times each tab has been left, by router branch index.
///
/// **A tab you leave is a fresh screen when you come back.** Every tab stays
/// mounted for the life of the shell - that is what lets the strip slide
/// between them - and so did everything done on it: the profile photo opened
/// full-bleed was still open, a list was still half scrolled, a search still
/// typed. "The avatar stays enlarged when you go back; pages and open tabs
/// should not keep their state" was the report.
///
/// Rebuilt a moment after the tab has slid out of sight rather than the
/// instant it is left, so nobody watches it reset on its way out.
///
/// It is not a performance change, and it was asked about as one. A tab off
/// screen is `Offstage` with its tickers stopped (see `BranchContainer`): it is
/// not laid out, not painted and not animated, so it costs no frame time
/// whatever state it holds. What resetting it saves is memory, not heat.
class TabGenerations extends Notifier<Map<int, int>> {
  int? _current;
  final Map<int, Timer> _pending = {};

  /// Longer than the strip's longest slide (320 ms in `BranchContainer`).
  static const Duration _afterSlide = Duration(milliseconds: 450);

  @override
  Map<int, int> build() {
    ref.onDispose(() {
      for (final timer in _pending.values) {
        timer.cancel();
      }
    });
    return const {};
  }

  /// The tab now showing. Safe to call from a build: it only schedules.
  void noteCurrent(int branch) {
    final previous = _current;
    _current = branch;
    _pending.remove(branch)?.cancel();
    if (previous == null || previous == branch) return;
    _pending[previous]?.cancel();
    _pending[previous] = Timer(_afterSlide, () {
      _pending.remove(previous);
      if (_current == previous) return;
      state = {...state, previous: (state[previous] ?? 0) + 1};
    });
  }
}

final tabGenerationsProvider =
    NotifierProvider<TabGenerations, Map<int, int>>(TabGenerations.new);

/// A tab's screen, rebuilt from nothing each time the tab has been left.
class TabReset extends ConsumerWidget {
  const TabReset({super.key, required this.branch, required this.child});

  final int branch;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final generation = ref.watch(
      tabGenerationsProvider.select((g) => g[branch] ?? 0),
    );
    return KeyedSubtree(key: ValueKey(generation), child: child);
  }
}
