import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// What the process spends CPU on, broken down by thread.
///
/// The frame panel next to this one answers "how expensive is a frame", split
/// into the UI thread and the GPU thread. That split has been enough to reject
/// two wrong theories, but it has a blind spot big enough to have cost a whole
/// round of work: it only sees *frames*. Bluetooth scanning, GATT notifications,
/// relay sockets, Hive writes and JSON decoding all happen on threads the frame
/// timings do not mention at all, and a phone can be warm with both frame
/// numbers looking healthy — which is roughly the report this app kept getting.
///
/// Linux already keeps the answer. `/proc/self/task/<tid>/stat` holds the
/// user and system time each thread has burned since it started, in USER_HZ
/// ticks, and the thread names are the ones the engine and the plugins chose:
/// `1.ui`, `1.raster`, `1.io`, `Binder:…` for every platform channel,
/// `DartWorker` for isolates. Two samples and a subtraction turn that into "this
/// thread used N ms of CPU during the window you were scrolling", which is the
/// sentence nothing in this app could previously produce.
///
/// Android only. `/proc` is not readable on iOS, [supported] says so, and the
/// panel hides itself rather than showing zeroes.
class CpuProbe {
  CpuProbe._();

  static final CpuProbe instance = CpuProbe._();

  /// USER_HZ. Fixed at 100 for the Linux userspace ABI regardless of the
  /// kernel's own tick rate, so one tick is 10 ms of CPU.
  static const int _msPerTick = 10;

  static final Directory _taskDir = Directory('/proc/self/task');

  /// Whether this platform exposes the counters at all.
  ///
  /// Checked by looking, not by asking the platform: an Android that has
  /// tightened `/proc` visibility should fall into the same "no data" branch as
  /// iOS rather than throw on every sample.
  bool get supported {
    if (!Platform.isAndroid) return false;
    try {
      return _taskDir.existsSync();
    } catch (_) {
      return false;
    }
  }

  Map<String, int>? _baseline;
  DateTime? _baselineAt;

  /// Start (or restart) a measuring window. Cheap — one pass over a directory
  /// of a few dozen small files, nothing left running afterwards.
  void begin() {
    _baseline = _sample();
    _baselineAt = DateTime.now();
  }

  /// True once [begin] has taken a usable baseline.
  bool get hasBaseline => _baseline != null;

  /// CPU burned per thread since [begin], busiest first.
  ///
  /// Empty when unsupported, when no baseline was taken, or when nothing has
  /// used a measurable amount yet — all three are "nothing to show", and the
  /// panel treats them the same.
  CpuReport? report() {
    final base = _baseline;
    final since = _baselineAt;
    if (base == null || since == null) return null;
    final now = _sample();
    if (now == null) return null;

    final elapsedMs = DateTime.now().difference(since).inMilliseconds;
    if (elapsedMs <= 0) return null;

    final rows = <CpuThread>[];
    var totalMs = 0;
    now.forEach((name, ticks) {
      // A thread that did not exist at baseline counts from zero, which is
      // exactly right: it did all of its work inside the window.
      final delta = ticks - (base[name] ?? 0);
      if (delta <= 0) return;
      final ms = delta * _msPerTick;
      totalMs += ms;
      rows.add(CpuThread(name, ms, ms * 100 / elapsedMs));
    });
    rows.sort((a, b) => b.cpuMs.compareTo(a.cpuMs));
    return CpuReport(
      threads: rows,
      totalCpuMs: totalMs,
      wallMs: elapsedMs,
    );
  }

  void reset() {
    _baseline = null;
    _baselineAt = null;
  }

  /// Ticks per thread, grouped by [_label]. Null when `/proc` is unreadable.
  Map<String, int>? _sample() {
    if (!Platform.isAndroid) return null;
    final int mainTid;
    try {
      mainTid = _pidOfSelf();
    } catch (_) {
      return null;
    }
    final threads = <int, ThreadStat>{};
    try {
      for (final entry in _taskDir.listSync(followLinks: false)) {
        // Each entry is `/proc/self/task/<tid>`; the directory name is the id.
        final slash = entry.path.lastIndexOf('/');
        final tid = int.tryParse(entry.path.substring(slash + 1));
        if (tid == null) continue;
        final parsed = _readThread(tid);
        if (parsed == null) continue;
        threads[tid] = parsed;
      }
    } catch (_) {
      // Threads come and go while we walk the directory; a vanished one is not
      // a failed measurement.
    }
    if (threads.isEmpty) return null;

    // Recent Flutter runs Dart on the platform thread rather than on a thread
    // of its own, so rebuilds land in the main thread's row and the row is
    // worth naming for it. Detected by CPU, not by presence: looking for an
    // `<n>.ui` thread and calling it "not merged" was wrong on a phone that
    // runs a second engine for the map — that engine's idle ui thread existed
    // while Dart was plainly on the main one. A ui thread that has burned
    // essentially nothing is not where the work is.
    final uiMs = threads.values
        .where(_isEngineUiThread)
        .fold<int>(0, (a, t) => a + t.ticks);
    final mainTicks = threads[mainTid]?.ticks ?? 0;
    final merged = uiMs * 4 < mainTicks;

    final out = <String, int>{};
    threads.forEach((tid, stat) {
      final label = _label(
        stat.comm,
        isMain: tid == mainTid,
        mergedUi: merged,
      );
      out[label] = (out[label] ?? 0) + stat.ticks;
    });
    return out;
  }

  /// Whether this is the engine's own UI thread, i.e. `<engine id>.ui`.
  static bool _isEngineUiThread(ThreadStat stat) {
    final dot = stat.comm.indexOf('.');
    return dot > 0 &&
        int.tryParse(stat.comm.substring(0, dot)) != null &&
        stat.comm.substring(dot + 1) == 'ui';
  }

  static int _pidOfSelf() {
    // `/proc/self/stat` opens as the calling process, so its first field is the
    // pid — which is also the tid of the platform (main) thread.
    final line = File('/proc/self/stat').readAsStringSync();
    return int.parse(line.substring(0, line.indexOf(' ')));
  }

  /// One thread's name and its utime+stime.
  static ThreadStat? _readThread(int tid) {
    try {
      return parseStat(File('/proc/self/task/$tid/stat').readAsStringSync());
    } catch (_) {
      return null;
    }
  }

  /// Thread name and utime+stime out of one `stat` line.
  ///
  /// Split out because it is worth a test of its own: reading the wrong field
  /// here does not fail, it returns plausible numbers taken from `majflt` or
  /// `cutime`, and the only place that would ever show up is a screenshot from
  /// a phone — a full round trip to discover the measurement was fiction.
  ///
  /// Parsed from the *last* `)` rather than by splitting the whole line. The
  /// second field is the thread name in parentheses and may itself contain
  /// spaces and parentheses (`Jit thread pool`, `(unnamed)`), which is the
  /// classic way a naive split of this file goes wrong.
  @visibleForTesting
  static ThreadStat? parseStat(String line) {
    try {
      final open = line.indexOf('(');
      final close = line.lastIndexOf(')');
      if (open < 0 || close <= open) return null;
      final comm = line.substring(open + 1, close);
      // Fields resume at `state`, which is field 3; utime is 14 and stime 15,
      // so 11 and 12 counting from here.
      final rest = line.substring(close + 2).split(' ');
      if (rest.length < 13) return null;
      final utime = int.tryParse(rest[11]);
      final stime = int.tryParse(rest[12]);
      if (utime == null || stime == null) return null;
      return ThreadStat(comm, utime + stime);
    } catch (_) {
      return null;
    }
  }

  /// Turn a kernel thread name into something worth reading in a screenshot.
  ///
  /// Two jobs. One is naming the engine's threads after what they do, because
  /// `1.raster` means nothing to the person sending the screenshot and "GPU
  /// raster" lines up with the panel above. The other is collapsing pools:
  /// platform channels arrive on `Binder:12345_3` and there are a dozen of
  /// them, each individually near zero and collectively the whole story — split
  /// out they sort below the noise and say nothing.
  @visibleForTesting
  static String label(
    String comm, {
    required bool isMain,
    bool mergedUi = false,
  }) =>
      _label(comm, isMain: isMain, mergedUi: mergedUi);

  static String _label(
    String comm, {
    required bool isMain,
    required bool mergedUi,
  }) {
    if (isMain) return mergedUi ? 'platform + Dart UI' : 'platform (main)';
    // The engine prefixes its threads with the engine id, so `1.ui` on the
    // first engine and `2.ui` on a second one.
    final dot = comm.indexOf('.');
    if (dot > 0 && int.tryParse(comm.substring(0, dot)) != null) {
      switch (comm.substring(dot + 1)) {
        case 'ui':
          return 'Dart UI';
        case 'raster':
        case 'gpu':
          return 'GPU raster';
        case 'io':
          return 'image decode';
        case 'profiler':
          return 'profiler';
      }
    }
    if (comm.startsWith('Binder:')) return 'Binder (platform channels)';
    if (comm.startsWith('DartWorker')) return 'Dart workers';
    if (comm.startsWith('pool-')) return 'Java pool';
    if (comm.startsWith('hwuiTask')) return 'hwui';
    if (comm.startsWith('Jit ')) return 'JIT';
    if (comm.startsWith('HeapTaskDaemon') ||
        comm.startsWith('ReferenceQueue') ||
        comm.startsWith('FinalizerDaemon') ||
        comm.startsWith('FinalizerWatch')) {
      return 'Java GC';
    }
    return comm;
  }
}

class ThreadStat {
  const ThreadStat(this.comm, this.ticks);
  final String comm;
  final int ticks;
}

/// One thread group's share of the measuring window.
class CpuThread {
  const CpuThread(this.name, this.cpuMs, this.percentOfOneCore);
  final String name;
  final int cpuMs;

  /// Percent of a single core. Can exceed 100 for a grouped row — a dozen
  /// binder threads genuinely can burn more than one core between them.
  final double percentOfOneCore;
}

/// Everything [CpuProbe.report] found, plus the window it covers.
class CpuReport {
  const CpuReport({
    required this.threads,
    required this.totalCpuMs,
    required this.wallMs,
  });

  final List<CpuThread> threads;
  final int totalCpuMs;
  final int wallMs;

  /// Whole-process CPU as a percentage of one core.
  double get totalPercentOfOneCore => wallMs == 0 ? 0 : totalCpuMs * 100 / wallMs;

  /// Threads that did nothing get no row, so a short list is normal; this is
  /// what the panel shows.
  List<CpuThread> top(int n) => threads.take(n).toList();

  /// The sentence the panel prints: which thread led, and by how much.
  ///
  /// It used to answer "rendering or not", by splitting the rows into ones that
  /// draw and ones that do not. That needs to know whether Dart is running on
  /// the platform thread, and there is no reliable way to tell from here — the
  /// first attempt looked for the engine's `<n>.ui` thread and treated its
  /// presence as "not merged", which a second engine (the map's platform view
  /// keeps one) makes false: a phone reported `platform (main)` leading with
  /// 8500 ms while build time over the same window came to 8520 ms, so Dart was
  /// plainly on it, and the panel said "not rendering, drawing is only 15%".
  ///
  /// So it no longer claims that. The panel above it already splits build from
  /// raster off the engine's own timings, which is the CPU-or-GPU answer and is
  /// not a guess; this one adds the part that panel cannot see — *which thread*
  /// — and stops there.
  String get verdict {
    if (threads.isEmpty || totalCpuMs == 0) return 'no CPU measured';
    final busiest = threads.first;
    final share = (busiest.cpuMs * 100 / totalCpuMs).round();
    if (threads.length == 1) return '${busiest.name} is all of it';
    return '${busiest.name} leads — $share% of the process';
  }
}
