import 'dart:async';

/// Runs one job per key at a time, and runs it again if it was asked for while
/// it was running.
///
/// The difference from simply dropping the overlapping call is the whole point,
/// and getting it wrong shipped in 987. A job that reads shared state does so
/// at some moment *after* it starts — for the receipt sweep, after two
/// encrypted boxes have finished opening — so it answers for the world as it
/// was at that moment. A request arriving during it carries news the job has
/// already gone past, and dropping that request loses the news for good.
///
/// The report it caused, in the words it arrived in: "4 смс первая
/// прочитуеться 3 нет, только перезаход помогает". Four messages land inside
/// two hundred milliseconds, the first sweep acknowledges whatever had arrived
/// when it looked, and the three calls for the rest are thrown away —
/// re-entering the chat is the user performing by hand the re-run this class
/// exists to perform for them.
///
/// One re-run covers any number of requests, because the second pass reads the
/// state fresh. And it cannot spin: a pass nobody asked to repeat is the last.
class Coalescer {
  final Set<Object> _running = <Object>{};
  final Set<Object> _again = <Object>{};

  /// True while [key] has a job in flight.
  bool isRunning(Object key) => _running.contains(key);

  /// True when a repeat has been requested and not yet served.
  bool isPending(Object key) => _again.contains(key);

  /// Run [job] for [key], repeating once more if asked during the run.
  ///
  /// [stopped] lets the owner abandon the loop on disposal rather than run a
  /// job against a torn-down world.
  Future<void> run(
    Object key,
    Future<void> Function() job, {
    bool Function()? stopped,
  }) async {
    if (!_running.add(key)) {
      _again.add(key);
      return;
    }
    try {
      while (true) {
        await job();
        if (stopped?.call() ?? false) return;
        if (!_again.remove(key)) return;
      }
    } finally {
      _running.remove(key);
      _again.remove(key);
    }
  }
}
