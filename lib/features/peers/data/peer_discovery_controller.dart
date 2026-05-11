import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ble/ble_permissions.dart';
import '../../../core/ble/ble_scanner.dart';
import '../models/discovered_peer.dart';
import 'peripheral_controller.dart';

/// All the things that can be wrong with BLE on the current device.
enum PeerDiscoveryStatus {
  /// Initial state before we've checked anything.
  idle,

  /// Platform doesn't ship BLE (e.g. iOS Simulator, Windows in dev).
  unsupported,

  /// User has not yet been asked for permission.
  permissionsUnknown,

  /// User actively denied permissions.
  permissionsDenied,

  /// User permanently denied — only Settings can unstick.
  permissionsPermanentlyDenied,

  /// Bluetooth radio is off / unauthorized / unavailable.
  adapterOff,

  /// Actively scanning.
  scanning,
}

@immutable
class PeerDiscoveryState {
  const PeerDiscoveryState({
    required this.status,
    required this.peers,
  });

  final PeerDiscoveryStatus status;
  final List<DiscoveredPeer> peers;

  PeerDiscoveryState copyWith({
    PeerDiscoveryStatus? status,
    List<DiscoveredPeer>? peers,
  }) {
    return PeerDiscoveryState(
      status: status ?? this.status,
      peers: peers ?? this.peers,
    );
  }

  static const initial = PeerDiscoveryState(
    status: PeerDiscoveryStatus.idle,
    peers: [],
  );
}

final blePermissionsProvider = Provider<BlePermissions>((_) => const BlePermissions());

final bleScannerProvider = Provider<BleScanner>((ref) {
  final scanner = BleScanner();
  ref.onDispose(() => unawaited(scanner.dispose()));
  return scanner;
});

final peerDiscoveryControllerProvider =
    NotifierProvider<PeerDiscoveryController, PeerDiscoveryState>(
  PeerDiscoveryController.new,
);

class PeerDiscoveryController extends Notifier<PeerDiscoveryState> {
  StreamSubscription<List<DiscoveredPeer>>? _peerSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;

  @override
  PeerDiscoveryState build() {
    ref.onDispose(_disposeSubscriptions);
    return PeerDiscoveryState.initial;
  }

  /// Top-level entry point. Idempotent — safe to call from initState every time
  /// the Peers screen is built.
  Future<void> start() async {
    final scanner = ref.read(bleScannerProvider);

    // Windows/Linux/macOS don't have meaningful BLE peripheral support yet,
    // and central support varies. Bail with a clear status.
    if (!Platform.isAndroid && !Platform.isIOS) {
      state = state.copyWith(status: PeerDiscoveryStatus.unsupported);
      return;
    }

    if (!await scanner.isSupported) {
      state = state.copyWith(status: PeerDiscoveryStatus.unsupported);
      return;
    }

    final perms = ref.read(blePermissionsProvider);
    final current = await perms.check();
    if (current != BlePermissionState.granted &&
        current != BlePermissionState.notApplicable) {
      state = state.copyWith(status: PeerDiscoveryStatus.permissionsUnknown);
      return;
    }

    await _wireStreams();
    final adapter = await FlutterBluePlus.adapterState.first;
    if (adapter != BluetoothAdapterState.on) {
      state = state.copyWith(status: PeerDiscoveryStatus.adapterOff);
      // Still start the scanner — it parks itself until the adapter comes up.
    } else {
      state = state.copyWith(status: PeerDiscoveryStatus.scanning);
    }

    if (!scanner.isRunning) {
      await scanner.start();
    }

    // Bring up the peripheral side too so other devices can find us.
    // Pulled into a microtask so a failure here doesn't block the scanner UI.
    unawaited(_bootPeripheral());
  }

  Future<void> _bootPeripheral() async {
    try {
      final peripheral = ref.read(peripheralControllerProvider.notifier);
      // Use the device's advertised name for now. M2 swaps this for the
      // user's Noise nickname + pubkey fingerprint.
      final defaultName = Platform.isIOS ? 'iPhone' : 'Android';
      await peripheral.start(peerName: defaultName);
    } catch (e, st) {
      debugPrint('peripheral boot failed: $e\n$st');
    }
  }

  Future<void> requestPermissions() async {
    final perms = ref.read(blePermissionsProvider);
    final result = await perms.request();
    switch (result) {
      case BlePermissionState.granted:
      case BlePermissionState.notApplicable:
        await start();
      case BlePermissionState.denied:
        state = state.copyWith(status: PeerDiscoveryStatus.permissionsDenied);
      case BlePermissionState.permanentlyDenied:
        state = state.copyWith(
          status: PeerDiscoveryStatus.permissionsPermanentlyDenied,
        );
    }
  }

  Future<void> openSettings() => ref.read(blePermissionsProvider).openSettings();

  Future<void> stop() async {
    await ref.read(bleScannerProvider).stop();
    _disposeSubscriptions();
    state = state.copyWith(status: PeerDiscoveryStatus.idle, peers: const []);
  }

  Future<void> _wireStreams() async {
    final scanner = ref.read(bleScannerProvider);
    await _peerSub?.cancel();
    _peerSub = scanner.peers.listen((peers) {
      state = state.copyWith(peers: peers);
    });
    await _adapterSub?.cancel();
    _adapterSub = scanner.adapterState.listen((s) {
      if (s == BluetoothAdapterState.on) {
        if (state.status == PeerDiscoveryStatus.adapterOff ||
            state.status == PeerDiscoveryStatus.idle) {
          state = state.copyWith(status: PeerDiscoveryStatus.scanning);
        }
      } else {
        state = state.copyWith(status: PeerDiscoveryStatus.adapterOff);
      }
    });
  }

  void _disposeSubscriptions() {
    _peerSub?.cancel();
    _adapterSub?.cancel();
    _peerSub = null;
    _adapterSub = null;
  }
}
