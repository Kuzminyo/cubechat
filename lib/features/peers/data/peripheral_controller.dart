import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ble/ble_peripheral.dart';
import '../../../core/ble/ble_permissions.dart';

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
  StreamSubscription<PeripheralEvent>? _eventsSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;

  @override
  PeripheralState build() {
    ref.onDispose(() {
      _eventsSub?.cancel();
      _adapterSub?.cancel();
      // Best-effort stop; native side handles a missing plugin gracefully.
      unawaited(ref.read(blePeripheralProvider).stop());
    });
    return PeripheralState.initial;
  }

  /// Boot the peripheral. Idempotent — safe to call multiple times.
  ///
  /// [peerName] is the human-readable label shown in scan results. Will be
  /// replaced with the Noise pubkey nickname once M2 lands.
  Future<void> start({required String peerName, String? pubkeyFingerprint}) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      state = state.copyWith(status: PeripheralStatus.unsupported);
      return;
    }

    final peripheral = ref.read(blePeripheralProvider);
    if (!await peripheral.isSupported()) {
      state = state.copyWith(status: PeripheralStatus.unsupported);
      return;
    }

    final perms = await const BlePermissions().check();
    if (perms != BlePermissionState.granted && perms != BlePermissionState.notApplicable) {
      state = state.copyWith(status: PeripheralStatus.notReady);
      return;
    }

    await _wireEvents();

    final adapter = await FlutterBluePlus.adapterState.first;
    if (adapter != BluetoothAdapterState.on) {
      state = state.copyWith(status: PeripheralStatus.notReady);
      return;
    }

    final ok = await peripheral.start(
      peerName: peerName,
      pubkeyFingerprint: pubkeyFingerprint,
    );
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

  Future<void> _wireEvents() async {
    final peripheral = ref.read(blePeripheralProvider);

    await _eventsSub?.cancel();
    _eventsSub = peripheral.events().listen((event) {
      switch (event) {
        case PeripheralCentralConnected(:final centralId):
          state = state.copyWith(
            connectedCentralIds: {...state.connectedCentralIds, centralId},
          );
        case PeripheralCentralDisconnected(:final centralId):
          state = state.copyWith(
            connectedCentralIds: {...state.connectedCentralIds}..remove(centralId),
          );
        case PeripheralWrite():
          // Inbound frame from a central — will be routed to the mesh layer in M3.
          break;
        case PeripheralUnknown():
          break;
      }
    }, onError: (Object e, StackTrace st) {
      debugPrint('peripheral events error: $e\n$st');
    });

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
