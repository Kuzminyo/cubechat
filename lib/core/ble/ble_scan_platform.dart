import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_constants.dart';

/// The few radio calls [BleScanner] makes, behind a seam so the order of
/// starts and stops can be tested off-device. Production uses this class as
/// it is; tests subclass it.
class BleScanPlatform {
  const BleScanPlatform();

  Stream<BluetoothAdapterState> get adapterState =>
      FlutterBluePlus.adapterState;

  bool get isOn => FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on;

  bool get isScanning => FlutterBluePlus.isScanningNow;

  Future<void> startScan({
    required Duration timeout,
    required AndroidScanMode mode,
    required bool continuousUpdates,
  }) =>
      FlutterBluePlus.startScan(
        withServices: [Guid(BleConstants.serviceUuid)],
        timeout: timeout,
        androidScanMode: mode,
        continuousUpdates: continuousUpdates,
      );

  Future<void> stopScan() => FlutterBluePlus.stopScan();

  Stream<List<ScanResult>> get scanResults => FlutterBluePlus.scanResults;
}

/// Android stops returning scan results — silently, no error — after five
/// `startScan` calls inside 30 s. This remembers when scans were started and
/// says how long the next start should wait to stay at four, one short of the
/// limit.
///
/// 1109's proximity window restarted every 10.3 s (about three starts per
/// 30 s on its own) and restarted again on every arrival on the AirDrop page,
/// so switching tabs a couple of times was enough to blind the scan.
class ScanStartBudget {
  ScanStartBudget({this.maxStarts = 4, this.per = const Duration(seconds: 30)});

  final int maxStarts;
  final Duration per;

  /// A little past the moment the oldest start ages out, so the platform's
  /// clock and ours need not agree to the millisecond.
  static const Duration _slack = Duration(milliseconds: 250);

  final List<DateTime> _starts = [];

  void record(DateTime at) {
    _prune(at);
    _starts.add(at);
  }

  /// Zero when a start now keeps within the budget.
  Duration waitBefore(DateTime now) {
    _prune(now);
    if (_starts.length < maxStarts) return Duration.zero;
    final oldest = _starts[_starts.length - maxStarts];
    final wait = oldest.add(per).add(_slack).difference(now);
    return wait.isNegative ? Duration.zero : wait;
  }

  void _prune(DateTime now) =>
      _starts.removeWhere((t) => now.difference(t) >= per);
}
