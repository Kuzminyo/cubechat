import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../features/peers/models/discovered_peer.dart';
import 'ble_constants.dart';

/// Cubechat central-role scanner.
///
/// Maintains a live `Map<deviceId, DiscoveredPeer>` and re-emits a snapshot
/// every time the picture changes (new peer, RSSI moved, stale peer dropped).
///
/// Restarts scan windows automatically so the radio gets a periodic rest —
/// continuous BLE scanning is a battery liability and on some Androids the
/// stack throttles us if we never stop.
class BleScanner {
  BleScanner();

  final _peers = <String, DiscoveredPeer>{};
  final _controller = StreamController<List<DiscoveredPeer>>.broadcast();
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  Timer? _cycleTimer;
  Timer? _gcTimer;
  bool _running = false;

  Stream<List<DiscoveredPeer>> get peers => _controller.stream;
  Stream<BluetoothAdapterState> get adapterState => FlutterBluePlus.adapterState;

  Future<bool> get isSupported async => FlutterBluePlus.isSupported;

  bool get isRunning => _running;

  Future<void> start() async {
    if (_running) return;
    _running = true;

    _adapterSub = FlutterBluePlus.adapterState.listen((s) {
      if (s != BluetoothAdapterState.on && _scanSub != null) {
        _stopScanWindow();
      } else if (s == BluetoothAdapterState.on && _running && _scanSub == null) {
        unawaited(_startScanWindow());
      }
    });

    _gcTimer = Timer.periodic(const Duration(seconds: 4), (_) => _gcStalePeers());

    final adapter = await FlutterBluePlus.adapterState.first;
    if (adapter == BluetoothAdapterState.on) {
      await _startScanWindow();
    }
  }

  Future<void> stop() async {
    _running = false;
    _cycleTimer?.cancel();
    _gcTimer?.cancel();
    await _adapterSub?.cancel();
    _adapterSub = null;
    await _stopScanWindow();
    _peers.clear();
    _emit();
  }

  Future<void> _startScanWindow() async {
    if (!_running) return;
    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(BleConstants.serviceUuid)],
        timeout: BleConstants.scanWindow,
        androidScanMode: AndroidScanMode.balanced,
      );
    } catch (e, st) {
      debugPrint('BleScanner.startScan failed: $e\n$st');
    }

    _scanSub = FlutterBluePlus.scanResults.listen(_onResults);

    // After the window closes, rest then cycle again.
    _cycleTimer = Timer(BleConstants.scanWindow + BleConstants.scanGap, () async {
      await _stopScanWindow();
      if (_running) unawaited(_startScanWindow());
    });
  }

  Future<void> _stopScanWindow() async {
    _cycleTimer?.cancel();
    _cycleTimer = null;
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
    } catch (_) {
      // ignore — scan may have already been stopped by the platform.
    }
  }

  void _onResults(List<ScanResult> results) {
    var changed = false;
    final now = DateTime.now();
    for (final r in results) {
      final id = r.device.remoteId.str;
      final advertisedName = _resolveName(r);
      final existing = _peers[id];
      if (existing == null) {
        _peers[id] = DiscoveredPeer(
          id: id,
          advertisedName: advertisedName,
          rssi: r.rssi,
          lastSeen: now,
        );
        changed = true;
        continue;
      }
      // Update if RSSI moved meaningfully or name finally arrived.
      final rssiMoved = (existing.rssi - r.rssi).abs() >= 4;
      final nameChanged = existing.advertisedName != advertisedName;
      _peers[id] = existing.copyWith(
        advertisedName: advertisedName,
        rssi: r.rssi,
        lastSeen: now,
      );
      if (rssiMoved || nameChanged) changed = true;
    }
    if (changed) _emit();
  }

  String _resolveName(ScanResult r) {
    final adv = r.advertisementData.advName;
    if (adv.isNotEmpty) return adv;
    final platform = r.device.platformName;
    if (platform.isNotEmpty) return platform;
    return r.device.remoteId.str;
  }

  void _gcStalePeers() {
    final now = DateTime.now();
    final stale = _peers.entries
        .where((e) => !e.value.isConnected &&
            now.difference(e.value.lastSeen) > BleConstants.peerStaleAfter)
        .map((e) => e.key)
        .toList();
    if (stale.isEmpty) return;
    for (final id in stale) {
      _peers.remove(id);
    }
    _emit();
  }

  void _emit() {
    final snapshot = _peers.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    _controller.add(snapshot);
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}
