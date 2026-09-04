import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;

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
/// `1.ui`, `1.raster`, `1.io`, `binder:…` for every platform channel,
/// `DartWorker` for isolates. Two samples and a subtraction turn that into "this
/// thread used N ms of CPU during the window you were scrolling", which is the
/// sentence nothing in this app could previously produce.
///
/// Every read here is asynchronous, deliberately. A sample opens fifty-odd
/// small files, and the first version did it with `readAsStringSync` from
/// inside a `build()` — on the UI thread, on a screen that rebuilds on every
/// log line. The panel was then reporting a build cost it had itself created,
/// which is the one measurement error a diagnostic must not make.
///
/// iOS has no `/proc`, and for a long time that meant no panel there at all —
/// on the platform where the frame meter says "GPU-bound" just as loudly. Mach
/// keeps the same counters: `task_threads` plus
/// `thread_info(THREAD_EXTENDED_INFO)` gives a name and a user+system time per
/// thread, which is what `/proc/self/task/<tid>/stat` gives. That side lives in
/// `ios/Runner/CubechatCpuProbePlugin.swift` and answers on one channel; the
/// arithmetic, the grouping and the verdict below are shared, so both platforms
/// print the same sentence from the same code.
///
/// Anything else — desktop, web — has no source and [supported] says so; the
/// panel hides itself rather than showing zeroes.
class CpuProbe {
  CpuProbe._();

  static final CpuProbe instance = CpuProbe._();

  /// The iOS sampler. Absent on every other platform, and a missing handler
  /// reads as "no data" rather than as an error — same branch as an Android
  /// that has tightened `/proc`.
  static const MethodChannel _channel = MethodChannel('cubechat/cpu_probe');

  /// USER_HZ. Fixed at 100 for the Linux userspace ABI regardless of the
  /// kernel's own tick rate, so one tick is 10 ms of CPU.
  ///
  /// Microseconds are what everything past [_sample] works in, because iOS
  /// reports nanoseconds and quantising that down to Linux's 10 ms would throw
  /// away real numbers — a thread that used 3 ms would read as zero. Linux
  /// genuinely has nothing finer, so its ticks are simply widened here.
  static const int _usPerTick = 10000;

  /// The platform thread's row when it is only the platform thread.
  static const String mainLabel = 'platform (main)';

  /// The platform thread's row when the engine is running Dart on it too —
  /// see [CpuReport.mergedUiThread].
  static const String mergedMainLabel = 'platform + Dart UI';

  static const String dartUiLabel = 'Dart UI';

  /// Impeller's own worker threads — part of drawing, see [_label].
  static const String impellerLabel = 'Impeller (GPU)';

  static final Directory _taskDir = Directory('/proc/self/task');

  /// Bumped every time the measuring window is restarted, so a panel showing
  /// the previous window's numbers can drop them instead of displaying a
  /// 25-second total under a window that is one second old.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Whether this platform exposes the counters at all.
  ///
  /// On Android this is checked by looking rather than by asking: a device that
  /// has tightened `/proc` visibility should fall into the same "no data"
  /// branch as an unsupported platform rather than throw on every sample.
  ///
  /// iOS cannot be checked without a round trip, so it answers yes and lets the
  /// sample decide. That costs nothing: the panel already renders nothing when
  /// a report comes back empty, so a build whose native half is missing hides
  /// the panel exactly as before.
  bool get supported {
    if (Platform.isIOS) return true;
    if (!Platform.isAndroid) return false;
    try {
      return _taskDir.existsSync();
    } catch (_) {
      return false;
    }
  }

  Map<String, int>? _baseline;
  DateTime? _baselineAt;
  bool _baselineMerged = false;

  /// Start (or restart) a measuring window. Cheap — one pass over a directory
  /// of a few dozen small files, all of it off the UI thread, nothing left
  /// running afterwards.
  Future<void> begin() async {
    final snap = await _sample();
    if (snap == null) return;
    _baseline = snap.micros;
    _baselineAt = DateTime.now();
    _baselineMerged = snap.merged;
    revision.value++;
  }

  /// True once [begin] has taken a usable baseline.
  bool get hasBaseline => _baseline != null;

  /// CPU burned per thread since [begin], busiest first.
  ///
  /// Empty when unsupported, when no baseline was taken, or when nothing has
  /// used a measurable amount yet — all three are "nothing to show", and the
  /// panel treats them the same.
  Future<CpuReport?> report() async {
    final base = _baseline;
    final since = _baselineAt;
    if (base == null || since == null) return null;
    final snap = await _sample();
    if (snap == null) return null;

    final elapsedMs = DateTime.now().difference(since).inMilliseconds;
    // A second, not a millisecond. Ticks are 10 ms wide, so one landing inside
    // a window three milliseconds long reads as 333% of a core — the shape of
    // the nonsense this panel has printed before ("30 ms, 214% of a core, over
    // 0 s"). Reading nothing for the first second of a window is the honest
    // answer: there is nothing measured yet.
    if (elapsedMs < 1000) return null;

    final rows = <CpuThread>[];
    var totalMs = 0;
    snap.micros.forEach((name, us) {
      // A thread that did not exist at baseline counts from zero, which is
      // exactly right: it did all of its work inside the window.
      final delta = us - (base[name] ?? 0);
      if (delta <= 0) return;
      final ms = delta ~/ 1000;
      if (ms <= 0) return;
      totalMs += ms;
      rows.add(CpuThread(name, ms, ms * 100 / elapsedMs));
    });
    rows.sort((a, b) => b.cpuMs.compareTo(a.cpuMs));
    return CpuReport(
      threads: rows,
      totalCpuMs: totalMs,
      wallMs: elapsedMs,
      mergedUiThread: snap.merged || _baselineMerged,
    );
  }

  void reset() {
    _baseline = null;
    _baselineAt = null;
    _baselineMerged = false;
    revision.value++;
  }

  /// Microseconds per thread, grouped by [_label]. Null when there is no
  /// source on this platform, or the source refused to answer.
  Future<_Snapshot?> _sample() {
    if (Platform.isIOS) return _sampleMach();
    if (Platform.isAndroid) return _sampleProc();
    return Future<_Snapshot?>.value();
  }

  /// The Mach walk, done natively — see `CubechatCpuProbePlugin.swift`.
  ///
  /// The native half deliberately decides nothing: it returns a name, a
  /// microsecond total and whether the thread is the platform one, and every
  /// judgement about what those mean is made here, where it can be tested
  /// without a phone.
  Future<_Snapshot?> _sampleMach() async {
    final List<Object?> raw;
    try {
      final reply = await _channel.invokeMethod<List<Object?>>('sample');
      if (reply == null || reply.isEmpty) return null;
      raw = reply;
    } catch (_) {
      // No handler in this build, or the walk failed. Both are "no data".
      return null;
    }

    final threads = <({String comm, bool isMain, int micros})>[];
    var dartUiMicros = 0;
    var mainMicros = 0;
    for (final row in raw) {
      if (row is! Map) continue;
      final comm = row['name'] as String? ?? '';
      final micros = row['us'] as int? ?? 0;
      final isMain = row['main'] == true;
      if (isMain) {
        mainMicros += micros;
      } else if (_engineRole(comm) == 'ui') {
        dartUiMicros += micros;
      }
      threads.add((comm: comm, isMain: isMain, micros: micros));
    }
    if (threads.isEmpty) return null;

    // Same rule as Android, and it should answer differently here: iOS runs
    // the UI task runner on its own thread, so the platform row and the Dart
    // row stay separate and the verdict can talk about drawing share again.
    // Asked rather than assumed, because that is a fact about the engine's
    // threading policy and not one this file gets to hold an opinion on.
    final merged = mergedByLoad(
      dartUiTicks: dartUiMicros,
      mainTicks: mainMicros,
    );
    final out = <String, int>{};
    for (final t in threads) {
      final label = _label(t.comm, isMain: t.isMain, merged: merged);
      out[label] = (out[label] ?? 0) + t.micros;
    }
    return _Snapshot(out, merged);
  }

  Future<_Snapshot?> _sampleProc() async {
    final int mainTid;
    try {
      mainTid = await _pidOfSelf();
    } catch (_) {
      return null;
    }

    final tids = <int>[];
    try {
      await for (final entry in _taskDir.list(followLinks: false)) {
        // Each entry is `/proc/self/task/<tid>`; the directory name is the id.
        final slash = entry.path.lastIndexOf('/');
        final tid = int.tryParse(entry.path.substring(slash + 1));
        if (tid != null) tids.add(tid);
      }
    } catch (_) {
      // Threads come and go while we walk the directory; a vanished one is not
      // a failed measurement.
    }
    if (tids.isEmpty) return null;

    // Read them together rather than one after another. Fifty sequential
    // awaits stretch a "snapshot" over long enough for the busy threads to
    // move on, and the subtraction is only honest if both samples are taken
    // at something close to one instant.
    final stats = await Future.wait(tids.map(_readThread));

    final raw = <({String comm, bool isMain, int ticks})>[];
    var dartUiTicks = 0;
    var mainTicks = 0;
    for (var i = 0; i < stats.length; i++) {
      final parsed = stats[i];
      if (parsed == null) continue;
      final isMain = tids[i] == mainTid;
      if (isMain) {
        mainTicks = parsed.ticks;
      } else if (_engineRole(parsed.comm) == 'ui') {
        dartUiTicks += parsed.ticks;
      }
      raw.add((comm: parsed.comm, isMain: isMain, ticks: parsed.ticks));
    }
    if (raw.isEmpty) return null;

    // Merged when the platform thread is where Dart actually runs — decided by
    // load, not by whether a `<n>.ui` thread exists anywhere in the walk.
    //
    // Presence was the first rule and it is wrong on this app specifically: the
    // map tab runs a second Flutter engine, and that engine keeps a `2.ui`
    // thread which sits idle. A phone in that state reported `platform (main)`
    // with 8500 ms against a build total of 8520 ms over the same window —
    // every rebuild was on the main thread while a ui thread existed and did
    // nothing. A ui thread that has burned a quarter of what the main thread
    // has is not where the work is.
    final merged = mergedByLoad(
      dartUiTicks: dartUiTicks,
      mainTicks: mainTicks,
    );
    final out = <String, int>{};
    for (final t in raw) {
      final label = _label(t.comm, isMain: t.isMain, merged: merged);
      out[label] = (out[label] ?? 0) + t.ticks * _usPerTick;
    }
    return _Snapshot(out, merged);
  }

  /// Whether the platform thread is where Dart is running, judged by load.
  ///
  /// Exposed so the rule has a test: it cannot be checked through [_sample],
  /// which needs a real `/proc`, and the threshold is the whole of the
  /// decision. A ui thread that has burned under a quarter of what the main
  /// thread has is not where the widget work is.
  @visibleForTesting
  static bool mergedByLoad({
    required int dartUiTicks,
    required int mainTicks,
  }) =>
      dartUiTicks * 4 < mainTicks;

  static Future<int> _pidOfSelf() async {
    // `/proc/self/stat` opens as the calling process, so its first field is the
    // pid — which is also the tid of the platform (main) thread.
    final line = await File('/proc/self/stat').readAsString();
    return int.parse(line.substring(0, line.indexOf(' ')));
  }

  /// One thread's name and its utime+stime.
  static Future<ThreadStat?> _readThread(int tid) async {
    try {
      return parseStat(await File('/proc/self/task/$tid/stat').readAsString());
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
  /// platform channels arrive on `binder:12345_3` and there are a dozen of
  /// them, each individually near zero and collectively the whole story — split
  /// out they sort below the noise and say nothing.
  ///
  /// [merged] renames the main thread when the engine is running Dart on it;
  /// the caller decides that by looking for a `<n>.ui` thread.
  @visibleForTesting
  static String label(
    String comm, {
    required bool isMain,
    bool merged = false,
  }) =>
      _label(comm, isMain: isMain, merged: merged);

  static String _label(
    String comm, {
    required bool isMain,
    required bool merged,
  }) {
    if (isMain) return merged ? mergedMainLabel : mainLabel;
    switch (_engineRole(comm)) {
      case 'ui':
        return dartUiLabel;
      case 'raster':
      case 'gpu':
        return 'GPU raster';
      case 'io':
        return 'image decode';
      case 'profiler':
        return 'profiler';
    }
    // Impeller's own threads. `IplrVkResMgr` reclaims Vulkan resources and
    // exists for exactly one reason — something is being drawn — so it belongs
    // with the drawing rows rather than sitting at the bottom of the list under
    // a name that reads like a driver nobody can place.
    if (comm.startsWith('Iplr')) return impellerLabel;
    // Case-insensitively: this is `Binder:` on some Android builds and
    // `binder:` on others, and the difference used to be one collapsed row
    // versus a dozen near-zero ones crowding the panel out.
    final lower = comm.toLowerCase();
    if (lower.startsWith('binder:')) return 'Binder (platform channels)';
    // Truncated by the kernel at 15 characters, so the real name
    // (`dart:io EventHandler`) never arrives intact.
    if (lower.startsWith('dart:io')) return 'dart:io';
    if (comm.startsWith('DartWorker')) return 'Dart workers';
    // --- iOS ------------------------------------------------------------
    // Same job as the binder collapse above: the dispatch pool arrives as a
    // dozen threads that are individually nothing and collectively the answer,
    // and most of them have no name at all. An unnamed row is honest — it is
    // where the work went — and a dozen empty rows are not.
    if (comm.isEmpty) return 'dispatch pool (unnamed)';
    if (comm.startsWith('com.apple.uikit')) return 'UIKit events';
    if (comm.startsWith('com.apple.CoreBluetooth') ||
        comm.startsWith('CoreBluetooth')) {
      return 'CoreBluetooth';
    }
    if (comm.startsWith('com.apple.NSURLConnection') ||
        comm.startsWith('com.apple.CFNetwork') ||
        comm.startsWith('com.apple.network')) {
      return 'networking';
    }
    if (comm.startsWith('com.apple.CoreMotion')) return 'CoreMotion';
    if (comm.startsWith('com.apple.root')) return 'dispatch pool';
    // `caulk` is CoreAudio's own scheduler; it means audio is running, which
    // is what the row should say rather than a name nobody can place.
    if (comm.startsWith('caulk') || comm.startsWith('AVAudio')) return 'audio';
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

  /// `1.ui` -> `ui`. The engine prefixes its threads with the engine id, so
  /// `1.ui` on the first engine and `2.ui` on a second one. Null for anything
  /// that is not one of them.
  ///
  /// iOS spells the same threads `io.flutter.1.ui`: Linux truncates a thread
  /// name at 15 characters and the engine shortens them to fit, Mach allows 64
  /// and it does not. The prefix is dropped here so everything downstream sees
  /// one spelling — and so a screenshot from either phone has the same rows in
  /// it, which is the entire point of doing this twice.
  static String? _engineRole(String comm) {
    final name = comm.startsWith(_iosEnginePrefix)
        ? comm.substring(_iosEnginePrefix.length)
        : comm;
    final dot = name.indexOf('.');
    if (dot <= 0) return null;
    if (int.tryParse(name.substring(0, dot)) == null) return null;
    return name.substring(dot + 1);
  }

  static const String _iosEnginePrefix = 'io.flutter.';
}

/// One pass over whichever source this platform has: microseconds per label,
/// plus whether the engine was found running Dart on the platform thread.
class _Snapshot {
  const _Snapshot(this.micros, this.merged);
  final Map<String, int> micros;
  final bool merged;
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
    this.mergedUiThread = false,
  });

  final List<CpuThread> threads;
  final int totalCpuMs;
  final int wallMs;

  /// Whether the engine ran Dart on the platform thread during the window.
  ///
  /// Current Flutter merges the UI task runner into the platform thread on
  /// Android, and the kernel has one row for one thread — so `platform (main)`
  /// holds widget builds, layout and every platform channel callback at once,
  /// and no amount of reading `/proc` will separate them. This flag exists so
  /// the verdict says that instead of pretending the missing `Dart UI` row is
  /// a thread that did no work, which is how the panel came to print "not
  /// rendering, drawing is only 22%" directly underneath a frame panel
  /// reporting an 18 ms build.
  final bool mergedUiThread;

  /// Whole-process CPU as a percentage of one core.
  double get totalPercentOfOneCore => wallMs == 0 ? 0 : totalCpuMs * 100 / wallMs;

  /// Threads that did nothing get no row, so a short list is normal; this is
  /// what the panel shows.
  List<CpuThread> top(int n) => threads.take(n).toList();

  static const Set<String> _drawing = {
    CpuProbe.dartUiLabel,
    'GPU raster',
    'image decode',
    CpuProbe.impellerLabel,
  };

  /// The whole window on one line, for the log.
  ///
  /// The panel is a screen, and a screen has to be photographed to be shared.
  /// A window that ends while nobody is looking at it — coming back from the
  /// background — has no screen to be photographed at all, and that is exactly
  /// the window worth reading. Same numbers, in a form that survives.
  String get summary {
    final rows = top(4).map(
      (t) => '${t.name} ${t.cpuMs} ms '
          '(${t.percentOfOneCore.toStringAsFixed(0)}%)',
    );
    return '${rows.join(', ')} over ${(wallMs / 1000).toStringAsFixed(0)} s';
  }

  /// The sentence the panel exists to print.
  ///
  /// Deliberately about *where*, not about *how much*: the absolute number
  /// depends on the phone, but "the thread doing the work is not one that draws
  /// anything" is a conclusion that holds on any of them.
  String get verdict {
    if (threads.isEmpty || totalCpuMs == 0) return 'no CPU measured';
    final busiest = threads.first;
    final drawingMs = threads
        .where((t) => _drawing.contains(t.name))
        .fold<int>(0, (a, t) => a + t.cpuMs);

    if (mergedUiThread) {
      // The drawing share cannot be computed at all here: the thread that
      // builds frames is the same row as the thread that answers Bluetooth.
      // What still survives is the comparison between that row and the others,
      // which is what the panel was built to ask.
      if (busiest.name != CpuProbe.mergedMainLabel) {
        // Says "used the most", not "leads". It named a busiest thread in the
        // same green the frame panel uses for "inside budget", directly under a
        // percentage printed in red, and it was read as a fault on a phone
        // whose frames were entirely fine — build p90 1.1 ms, raster p90 5.2,
        // two frames of 317 over budget. This panel is about share; whether
        // that share is a problem is the question the frame panel above
        // answers, and this now says so instead of implying its own verdict.
        final share = (busiest.cpuMs * 100 / totalCpuMs).round();
        return '${busiest.name} used the most CPU ($share%) — whether that is '
            'too much is what the frame numbers above say';
      }
      final share = (busiest.cpuMs * 100 / totalCpuMs).round();
      return 'UI thread leads with $share% — it also runs the platform side, '
          'so read the build/raster split above';
    }

    final drawingShare = drawingMs * 100 / totalCpuMs;
    if (drawingShare >= 60) {
      return 'rendering — ${drawingShare.round()}% of CPU is drawing';
    }
    if (drawingShare <= 30) {
      return 'not rendering — ${busiest.name} leads, drawing is only '
          '${drawingShare.round()}%';
    }
    return 'mixed — drawing is ${drawingShare.round()}% of CPU';
  }
}
