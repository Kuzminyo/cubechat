import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ble_constants.dart';

/// Peripheral-role contract for the Cubechat mesh.
///
/// `flutter_blue_plus` is central-only; advertising and exposing a GATT server
/// requires platform code. This is the Dart side of a [MethodChannel] bridge
/// we wire up in M1.5 (Swift on iOS, Kotlin on Android).
///
/// Until that lands, calling [start] returns false and logs — it does *not*
/// throw, so the rest of the app can be developed with central-only behavior.
abstract class BlePeripheral {
  Future<bool> isSupported();
  Future<bool> start({required String peerName, String? pubkeyFingerprint});
  Future<void> stop();
  Stream<PeripheralEvent> events();

  /// Push a single frame to every subscribed central via the inbound (notify)
  /// characteristic. Returns true if at least one central received it.
  /// Returns false if there are no subscribers, the radio is off, or the
  /// native plugin isn't loaded.
  Future<bool> notifyInbound(Uint8List data);
}

/// Default implementation: talks to the (yet-to-be-written) platform channel.
class MethodChannelBlePeripheral implements BlePeripheral {
  MethodChannelBlePeripheral();

  static const _channel = MethodChannel('cubechat/ble_peripheral');
  static const _events = EventChannel('cubechat/ble_peripheral/events');

  @override
  Future<bool> isSupported() async {
    try {
      final result = await _channel.invokeMethod<bool>('isSupported');
      return result ?? false;
    } on MissingPluginException {
      // Native side not wired up yet — expected until M1.5.
      return false;
    } catch (e, st) {
      debugPrint('BlePeripheral.isSupported failed: $e\n$st');
      return false;
    }
  }

  @override
  Future<bool> start({required String peerName, String? pubkeyFingerprint}) async {
    try {
      final result = await _channel.invokeMethod<bool>('start', {
        'serviceUuid': BleConstants.serviceUuid,
        'inboundCharUuid': BleConstants.inboundCharUuid,
        'outboundCharUuid': BleConstants.outboundCharUuid,
        'peerInfoCharUuid': BleConstants.peerInfoCharUuid,
        'peerName': peerName,
        'pubkeyFingerprint': pubkeyFingerprint,
        'protocolVersion': BleConstants.protocolVersion,
      });
      return result ?? false;
    } on MissingPluginException {
      debugPrint('BlePeripheral.start: native side not yet implemented (M1.5).');
      return false;
    } catch (e, st) {
      debugPrint('BlePeripheral.start failed: $e\n$st');
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // No-op until M1.5.
    } catch (e, st) {
      debugPrint('BlePeripheral.stop failed: $e\n$st');
    }
  }

  @override
  Future<bool> notifyInbound(Uint8List data) async {
    try {
      final ok = await _channel.invokeMethod<bool>('notifyInbound', {'data': data});
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } catch (e, st) {
      debugPrint('BlePeripheral.notifyInbound failed: $e\n$st');
      return false;
    }
  }

  @override
  Stream<PeripheralEvent> events() {
    return _events.receiveBroadcastStream().map((dynamic raw) {
      final map = (raw as Map).cast<String, dynamic>();
      final type = map['type'] as String?;
      switch (type) {
        case 'connected':
          return PeripheralEvent.centralConnected(map['centralId'] as String);
        case 'disconnected':
          return PeripheralEvent.centralDisconnected(map['centralId'] as String);
        case 'write':
          return PeripheralEvent.write(
            centralId: map['centralId'] as String,
            charUuid: map['charUuid'] as String,
            data: map['data'] as Uint8List,
          );
        default:
          return const PeripheralEvent.unknown();
      }
    }).handleError((Object e, StackTrace st) {
      debugPrint('BlePeripheral.events stream error: $e\n$st');
    });
  }
}

@immutable
sealed class PeripheralEvent {
  const PeripheralEvent();

  const factory PeripheralEvent.centralConnected(String centralId) =
      PeripheralCentralConnected;
  const factory PeripheralEvent.centralDisconnected(String centralId) =
      PeripheralCentralDisconnected;
  const factory PeripheralEvent.write({
    required String centralId,
    required String charUuid,
    required Uint8List data,
  }) = PeripheralWrite;
  const factory PeripheralEvent.unknown() = PeripheralUnknown;
}

class PeripheralCentralConnected extends PeripheralEvent {
  const PeripheralCentralConnected(this.centralId);
  final String centralId;
}

class PeripheralCentralDisconnected extends PeripheralEvent {
  const PeripheralCentralDisconnected(this.centralId);
  final String centralId;
}

class PeripheralWrite extends PeripheralEvent {
  const PeripheralWrite({
    required this.centralId,
    required this.charUuid,
    required this.data,
  });
  final String centralId;
  final String charUuid;
  final Uint8List data;
}

class PeripheralUnknown extends PeripheralEvent {
  const PeripheralUnknown();
}
