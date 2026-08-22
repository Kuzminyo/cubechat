import 'package:flutter_test/flutter_test.dart';

import 'package:cubechat/core/util/cpu_probe.dart';

/// The parts of [CpuProbe] that can be tested off a phone: how a kernel thread
/// name becomes a label, and what conclusion a set of numbers leads to.
///
/// The `/proc` reading itself is not covered — there is no `/proc/self/task` on
/// the machine the tests run on, and a fixture directory would only prove the
/// fixture parses. The grouping and the verdict are where the reasoning lives,
/// and they are the two things a wrong answer would come out of.
void main() {
  group('label', () {
    test('names the engine threads after what they do', () {
      expect(CpuProbe.label('1.ui', isMain: false), 'Dart UI');
      expect(CpuProbe.label('1.raster', isMain: false), 'GPU raster');
      expect(CpuProbe.label('1.io', isMain: false), 'image decode');
      // A second engine (the map's platform view runs one) numbers its threads
      // differently and must land in the same rows.
      expect(CpuProbe.label('2.raster', isMain: false), 'GPU raster');
    });

    test('collapses the pools that only matter in aggregate', () {
      expect(
        CpuProbe.label('Binder:9312_4', isMain: false),
        CpuProbe.label('Binder:9312_7', isMain: false),
      );
      expect(
        CpuProbe.label('Binder:9312_4', isMain: false),
        'Binder (platform channels)',
      );
      expect(CpuProbe.label('pool-3-thread-2', isMain: false), 'Java pool');
      expect(CpuProbe.label('HeapTaskDaemon', isMain: false), 'Java GC');
    });

    test('the binder pool collapses whichever case the device spells it in', () {
      // Android 15 names them `binder:20054_9`; older builds capitalise it.
      // Matching only the capital B left a dozen near-zero rows that pushed
      // everything worth reading off a six-row panel.
      expect(
        CpuProbe.label('binder:20054_9', isMain: false),
        'Binder (platform channels)',
      );
      expect(
        CpuProbe.label('binder:20054_9', isMain: false),
        CpuProbe.label('Binder:20054_2', isMain: false),
      );
    });

    test('names the threads a modern engine actually creates', () {
      // Impeller's Vulkan resource manager. Drawing work under a name that
      // reads like a graphics driver, which is precisely how it sorted to the
      // bottom of the panel and told nobody anything.
      expect(CpuProbe.label('IplrVkResMgr', isMain: false), 'Impeller (GPU)');
      // The kernel truncates `comm` at 15 characters, so `dart:io
      // EventHandler` never arrives whole.
      expect(CpuProbe.label('dart:io EventHa', isMain: false), 'dart:io');
    });

    test('the main thread says so when it is also running Dart', () {
      expect(
        CpuProbe.label('m.cubechat.app', isMain: true, merged: true),
        'platform + Dart UI',
      );
    });

    test('an idle ui thread does not mean the main thread is only platform', () {
      // Presence was the first rule for this and it is wrong on this app: the
      // map tab runs a second Flutter engine whose `2.ui` thread exists and
      // sits idle. A phone in that state read `platform (main)` with 8500 ms
      // while build time over the same window came to 8520 ms — Dart was
      // plainly on the main thread. The label is decided by load now, and this
      // pins that the quarter-of-the-main-thread test is what does it.
      expect(CpuProbe.mergedByLoad(dartUiTicks: 0, mainTicks: 850), isTrue);
      expect(CpuProbe.mergedByLoad(dartUiTicks: 5, mainTicks: 850), isTrue);
      // A ui thread doing real work is a real ui thread.
      expect(CpuProbe.mergedByLoad(dartUiTicks: 400, mainTicks: 850), isFalse);
    });

    test('the main thread is named by its id, not by its comm', () {
      // It is named after the truncated package, which differs per flavour and
      // is unrecognisable in a screenshot.
      expect(CpuProbe.label('m.cubechat.app', isMain: true), 'platform (main)');
    });

    test('leaves an unrecognised thread alone', () {
      expect(CpuProbe.label('BluetoothGatt', isMain: false), 'BluetoothGatt');
    });
  });

  group('parseStat', () {
    // A real line, from `/proc/self/task/<tid>/stat` on Android 14. Fields:
    // pid, (comm), state, ppid, pgrp, session, tty_nr, tpgid, flags, minflt,
    // cminflt, majflt, cmajflt, utime, stime, ...
    const utime = 431;
    const stime = 96;
    const line = '9312 (1.raster) S 1180 9312 0 0 -1 1077936448 '
        '48211 0 3 0 $utime $stime 0 0 20 0 62 0 1049237 '
        '19153444864 41234 18446744073709551615 1 1 0 0 0 0 4612 1 1073775864';

    test('reads utime + stime, not the fields either side of them', () {
      final s = CpuProbe.parseStat(line);
      expect(s, isNotNull);
      expect(s!.comm, '1.raster');
      expect(s.ticks, utime + stime);
      // The neighbours, so an off-by-one lands on something this test rejects
      // rather than on a number that merely looks wrong on a phone.
      expect(s.ticks, isNot(0)); // cmajflt + utime
      expect(s.ticks, isNot(stime)); // stime alone
    });

    test('survives a thread name with spaces and parentheses', () {
      final s = CpuProbe.parseStat(
        '9401 (Jit thread pool) S 1180 9312 0 0 -1 1077936448 '
        '48211 0 3 0 7 2 0 0 20 0 62 0 1049237 19153444864 41234',
      );
      expect(s!.comm, 'Jit thread pool');
      expect(s.ticks, 9);
    });

    test('a truncated or unexpected line is no reading, not a wrong one', () {
      expect(CpuProbe.parseStat('9312 (1.ui) S 1180 9312'), isNull);
      expect(CpuProbe.parseStat('nonsense'), isNull);
      expect(CpuProbe.parseStat(''), isNull);
    });
  });

  group('verdict', () {
    CpuReport report(
      List<CpuThread> threads, {
      int wallMs = 10000,
      bool merged = false,
    }) {
      final total = threads.fold<int>(0, (a, t) => a + t.cpuMs);
      return CpuReport(
        threads: threads,
        totalCpuMs: total,
        wallMs: wallMs,
        mergedUiThread: merged,
      );
    }

    test('calls it rendering when the drawing threads dominate', () {
      final r = report([
        const CpuThread('GPU raster', 4000, 40),
        const CpuThread('Dart UI', 2000, 20),
        const CpuThread('Binder (platform channels)', 500, 5),
      ]);
      expect(r.verdict, contains('rendering'));
      expect(r.verdict, isNot(contains('not rendering')));
    });

    test('says so when the busiest thread does not draw anything', () {
      // The case the panel exists for: healthy frames, warm phone.
      final r = report([
        const CpuThread('Binder (platform channels)', 5000, 50),
        const CpuThread('Dart UI', 300, 3),
        const CpuThread('GPU raster', 200, 2),
      ]);
      expect(r.verdict, contains('not rendering'));
      expect(r.verdict, contains('Binder'));
    });

    test('percent of a core is CPU time over wall time', () {
      final r = report([const CpuThread('Dart UI', 5000, 50)], wallMs: 10000);
      expect(r.totalPercentOfOneCore, 50);
    });

    test('an empty window concludes nothing', () {
      expect(report(const []).verdict, 'no CPU measured');
    });

    test('Impeller counts as drawing', () {
      // Without this the raster work of an Impeller build sits outside the
      // drawing set and the panel concludes the opposite of the truth.
      final r = report([
        const CpuThread('GPU raster', 3000, 30),
        const CpuThread('Impeller (GPU)', 3000, 30),
        const CpuThread('Binder (platform channels)', 500, 5),
      ]);
      expect(r.verdict, contains('rendering'));
      expect(r.verdict, isNot(contains('not rendering')));
    });

    group('when the engine runs Dart on the platform thread', () {
      // The state every current Android build is in: there is no `1.ui`
      // thread, its work is inside `platform (main)`, and computing a drawing
      // share from what is left is how the panel came to print "not rendering,
      // drawing is only 22%" under a frame panel reporting an 18 ms build.
      test('does not call a busy UI thread "not rendering"', () {
        final r = report(
          [
            const CpuThread('platform + Dart UI', 1110, 4),
            const CpuThread('GPU raster', 400, 2),
            const CpuThread('Dart workers', 190, 1),
          ],
          wallMs: 25000,
          merged: true,
        );
        expect(r.verdict, isNot(contains('not rendering')));
        expect(r.verdict, contains('UI thread leads'));
      });

      test('still names a thread that outruns the UI thread', () {
        // The report the panel exists for, and the one thing that survives the
        // merge: something that draws nothing is busier than the frames.
        final r = report(
          [
            const CpuThread('Binder (platform channels)', 5000, 50),
            const CpuThread('platform + Dart UI', 400, 4),
          ],
          merged: true,
        );
        expect(r.verdict, contains('Binder'));
      });
    });

    test('top() is a ceiling, not a requirement', () {
      final r = report([
        const CpuThread('Dart UI', 300, 3),
        const CpuThread('GPU raster', 200, 2),
      ]);
      expect(r.top(6), hasLength(2));
    });
  });
}
