import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// What BLE-related permissions look like right now.
enum BlePermissionState {
  /// All permissions granted; we can scan, connect, and advertise.
  granted,

  /// User said no; we can still ask again from a button.
  denied,

  /// User checked "Don't ask again"; only Settings can flip this.
  permanentlyDenied,

  /// Platform doesn't surface these permissions (e.g. desktop). Treat as granted.
  notApplicable,
}

/// Runtime permission gate for the BLE stack.
///
/// On Android 12+ we need BLUETOOTH_SCAN + BLUETOOTH_CONNECT + BLUETOOTH_ADVERTISE.
/// On Android <= 11 we need ACCESS_FINE_LOCATION (declared maxSdk 30 in the manifest).
/// On iOS the per-permission dance is handled by CoreBluetooth itself — we just
/// trigger it implicitly the first time we scan.
class BlePermissions {
  const BlePermissions();

  Future<BlePermissionState> check() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return BlePermissionState.notApplicable;
    }
    if (Platform.isIOS) {
      // CoreBluetooth triggers the prompt on first use; nothing to pre-flight.
      return BlePermissionState.granted;
    }
    // Android
    final results = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
    ].map((p) => p.status).wait;

    return _aggregate(results);
  }

  Future<BlePermissionState> request() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return BlePermissionState.notApplicable;
    }
    if (Platform.isIOS) {
      return BlePermissionState.granted;
    }
    final results = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
    ].request();

    return _aggregate(results.values.toList());
  }

  Future<void> openSettings() => openAppSettings();

  BlePermissionState _aggregate(List<PermissionStatus> results) {
    if (results.every((s) => s.isGranted)) return BlePermissionState.granted;
    if (results.any((s) => s.isPermanentlyDenied)) {
      return BlePermissionState.permanentlyDenied;
    }
    return BlePermissionState.denied;
  }
}
