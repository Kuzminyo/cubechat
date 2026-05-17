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
    log.log('PERIPH-CTL', 'start(peerName=$peerName)');
    if (!PlatformInfo.isMobile) {
      log.log('PERIPH-CTL', 'unsupported platform');
      state = state.copyWith(status: PeripheralStatus.unsupported);
      return;
    }

    final peripheral = ref.read(blePeripheralProvider);
    if (!await peripheral.isSupported()) {
      log.log('PERIPH-CTL', 'native isSupported = false');
      state = state.copyWith(status: PeripheralStatus.unsupported);
      return;
    }

    final perms = await const BlePermissions().check();
    if (perms != BlePermissionState.granted && perms != BlePermissionState.notApplicable) {
      log.log('PERIPH-CTL', 'perms not granted: $perms');
      state = state.copyWith(status: PeripheralStatus.notReady);
      return;
    }

    await _wireAdapterWatcher();

    final adapter = await FlutterBluePlus.adapterState.first;
    if (adapter != BluetoothAdapterState.on) {
      log.log('PERIPH-CTL', 'adapter is $adapter, not starting');
      state = state.copyWith(status: PeripheralStatus.notReady);
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
    final peripheral = ref.read(blePeripheralProvider);
    await _adapterSub?.cancel();
    _adapterSub = FlutterBluePlus.adapterState.listen((s) async {
      if (s == BluetoothAdapterState.on) {
        if (state.status == PeripheralStatus.notReady ||
            state.status == PeripheralStatus.idle) {
          // Adapter came back; let the screen call start() again with a fresh name.
          state = state.copyWith(status: PeripheralStatus.idle);
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
