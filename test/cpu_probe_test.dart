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
      expect(CpuProbe.label('Binder:9312_4', isMain: false),
          'Binder (platform channels)');
      expect(CpuProbe.label('pool-3-thread-2', isMain: false), 'Java pool');
      expect(CpuProbe.label('HeapTaskDaemon', isMain: false), 'Java GC');
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

  group('verdict', () {
    CpuReport report(List<CpuThread> threads, {int wallMs = 10000}) {
      final total = threads.fold<int>(0, (a, t) => a + t.cpuMs);
      return CpuReport(threads: threads, totalCpuMs: total, wallMs: wallMs);
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

    test('top() is a ceiling, not a requirement', () {
      final r = report([
        const CpuThread('Dart UI', 300, 3),
        const CpuThread('GPU raster', 200, 2),
      ]);
      expect(r.top(6), hasLength(2));
    });
  });
}
