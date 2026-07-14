import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ble/ble_peripheral.dart';
import '../../../core/ble/ble_permissions.dart';
import '../../../core/util/debug_log.dart';
import '../../../core/util/platform_info.dart';

enum PeripheralStatus {
  /// Not started yet.
  idle,

  /// Platform / device does not support advertising.
  unsupported,

  /// Permissions or adapter not ready.
  notReady,

  /// Advertising and ready to be discovered.
  broadcasting,

  /// Native side reported a failure.
  failed,
}

@immutable
class PeripheralState {
  const PeripheralState({
    required this.status,
    required this.connectedCentralIds,
    this.lastError,
  });

  final PeripheralStatus status;
  final Set<String> connectedCentralIds;
  final String? lastError;

  int get connectedCount => connectedCentralIds.length;

  PeripheralState copyWith({
    PeripheralStatus? status,
    Set<String>? connectedCentralIds,
    String? lastError,
  }) {
    return PeripheralState(
      status: status ?? this.status,
      connectedCentralIds: connectedCentralIds ?? this.connectedCentralIds,
      lastError: lastError ?? this.lastError,
    );
  }

  static const initial = PeripheralState(
    status: PeripheralStatus.idle,
    connectedCentralIds: <String>{},
  );
}

final blePeripheralProvider = Provider<BlePeripheral>((_) => MethodChannelBlePeripheral());

final peripheralControllerProvider =
    NotifierProvider<PeripheralController, PeripheralState>(PeripheralController.new);

class PeripheralController extends Notifier<PeripheralState> {
  StreamSubscription<BluetoothAdapterState>? _adapterSub;

  /// Last name/fingerprint we were asked to advertise, replayed by the adapter
  /// watcher when Bluetooth returns.
  String? _lastPeerName;
  String? _lastFingerprint;

  /// True while a [start] is in flight. The adapter stream replays its current
  /// value to a new listener, so without this the watcher would re-enter
  /// [start] while the first call is still walking its checks.
  bool _starting = false;

  @override
  PeripheralState build() {
    ref.onDispose(() {
      _adapterSub?.cancel();
      // Best-effort stop; native side handles a missing plugin gracefully.
      unawaited(ref.read(blePeripheralProvider).stop());
    });
    return PeripheralState.initial;
  }

  /// Called by MessagingService when a central completes a GATT connection
  /// to our peripheral. We don't subscribe to peripheral.events() ourselves
  /// because EventChannel.receiveBroadcastStream() has a known
  /// quirk: each new Dart-side listener resets the channel's message
  /// handler, and the previous listener stops receiving. MessagingService
  /// is the sole consumer; it pushes us the events we care about.
  void onCentralConnected(String centralId) {
    state = state.copyWith(
      connectedCentralIds: {...state.connectedCentralIds, centralId},
    );
  }

  void onCentralDisconnected(String centralId) {
    state = state.copyWith(
      connectedCentralIds: {...state.connectedCentralIds}..remove(centralId),
    );
  }

  /// Boot the peripheral. Idempotent — safe to call multiple times.
  ///
  /// [peerName] is the human-readable label shown in scan results. Will be
  /// replaced with the Noise pubkey nickname once M2 lands.
  Future<void> start({required String peerName, String? pubkeyFingerprint}) async {
    final log = DebugLog.instance;
    if (_starting) {
      log.log('PERIPH-CTL', 'start already in flight — skipping');
      return;
    }
    log.log('PERIPH-CTL', 'start(peerName=$peerName)');
    // Remembered so the adapter watcher can restart advertising by itself when
    // Bluetooth comes back, without waiting for the screen to call us again.
    _lastPeerName = peerName;
    _lastFingerprint = pubkeyFingerprint;
    if (!PlatformInfo.isMobile) {
      log.log('PERIPH-CTL', 'unsupported platform');
      state = state.copyWith(status: PeripheralStatus.unsupported);
      return;
    }

    _starting = true;
    try {
      await _startChecked(peerName, pubkeyFingerprint, log);
    } finally {
      _starting = false;
    }
  }

  Future<void> _startChecked(
    String peerName,
    String? pubkeyFingerprint,
    DebugLog log,
  ) async {

    final perms = await const BlePermissions().check();
    if (perms != BlePermissionState.granted && perms != BlePermissionState.notApplicable) {
      log.log('PERIPH-CTL', 'perms not granted: $perms');
      state = state.copyWith(status: PeripheralStatus.notReady);
      return;
    }

    // Wire the watcher before any adapter-dependent bail-out — it's what
    // re-runs start() once Bluetooth is back. Wiring it after the checks meant
    // a phone whose adapter was down when the Peers screen opened stayed dark
    // until the app was restarted.
    await _wireAdapterWatcher();

    final adapter = await FlutterBluePlus.adapterState.first;
    if (adapter != BluetoothAdapterState.on) {
      log.log('PERIPH-CTL', 'adapter is $adapter, not starting');
      state = state.copyWith(status: PeripheralStatus.notReady);
      return;
    }

    // Ask the hardware only once permissions and the adapter are actually in
    // place. The native check reads BluetoothAdapter.bluetoothLeAdvertiser,
    // which is null while Bluetooth is off — asking first (as this used to)
    // brands a perfectly capable phone permanently "unsupported".
    final peripheral = ref.read(blePeripheralProvider);
    if (!await peripheral.isSupported()) {
      log.log('PERIPH-CTL', 'native isSupported = false — no BLE advertiser');
      state = state.copyWith(status: PeripheralStatus.unsupported);
      return;
    }

    log.log('PERIPH-CTL', 'calling native start…');
    final ok = await peripheral.start(
      peerName: peerName,
      pubkeyFingerprint: pubkeyFingerprint,
    );
    log.log('PERIPH-CTL', 'native start returned $ok');
    state = state.copyWith(
      status: ok ? PeripheralStatus.broadcasting : PeripheralStatus.failed,
    );
  }

  Future<void> stop() async {
    await ref.read(blePeripheralProvider).stop();
    state = state.copyWith(
      status: PeripheralStatus.idle,
      connectedCentralIds: const <String>{},
    );
  }

  Future<void> _wireAdapterWatcher() async {
    // Idempotent: start() calls this on every invocation, and the watcher can
    // itself call start() — cancelling and re-listening from inside our own
    // callback would be needlessly hairy.
    if (_adapterSub != null) return;
    final peripheral = ref.read(blePeripheralProvider);
    _adapterSub = FlutterBluePlus.adapterState.listen((s) async {
      if (s == BluetoothAdapterState.on) {
        final name = _lastPeerName;
        if (state.status != PeripheralStatus.broadcasting && name != null) {
          DebugLog.instance
              .log('PERIPH-CTL', 'adapter back on — re-starting advertising');
          await start(peerName: name, pubkeyFingerprint: _lastFingerprint);
        }
      } else {
        await peripheral.stop();
        state = state.copyWith(
          status: PeripheralStatus.notReady,
          connectedCentralIds: const <String>{},
        );
      }
    });
  }
}
