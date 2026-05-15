import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../ble/ble_constants.dart';

/// Central-side wrapper around a single [BluetoothDevice] that speaks the
/// cubechat GATT protocol.
///
/// One of these is created per outbound peer connection. It discovers our
/// service, latches the three characteristics, subscribes to inbound
/// notifications, and exposes a [Stream<Uint8List>] of received frames plus
/// a [writeOutbound] method.
class BleGattClient {
  BleGattClient(this._device);

  final BluetoothDevice _device;

  BluetoothCharacteristic? _inbound; // peripheral -> we receive notifications
  BluetoothCharacteristic? _outbound; // we write -> peripheral receives
  // ignore: unused_field — kept for peer-info reads in M5
  BluetoothCharacteristic? _peerInfo;

  StreamSubscription<List<int>>? _inboundSub;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;

  final _frames = StreamController<Uint8List>.broadcast();
  final _connection = StreamController<BluetoothConnectionState>.broadcast();

  bool _running = false;

  String get peerId => _device.remoteId.str;
  Stream<Uint8List> get inboundFrames => _frames.stream;
  Stream<BluetoothConnectionState> get connectionState => _connection.stream;
  bool get isConnected =>
      _device.isConnected;

  /// Connects to the device, discovers our service, finds the characteristics,
  /// and subscribes to inbound notifications. Throws if any step fails.
  Future<void> connect({Duration timeout = const Duration(seconds: 8)}) async {
    if (_running) return;
    _running = true;

    _connectionSub = _device.connectionState.listen((s) {
      _connection.add(s);
      if (s == BluetoothConnectionState.disconnected) {
        _running = false;
      }
    });

    await _device.connect(timeout: timeout, autoConnect: false);

    // Request a beefier MTU — defaults to 23 on iOS which is unusable.
    try {
      await _device.requestMtu(BleConstants.preferredMtu);
    } catch (e) {
      // iOS doesn't expose MTU negotiation; CoreBluetooth picks one. Fine.
      debugPrint('BleGattClient.requestMtu skipped: $e');
    }

    final services = await _device.discoverServices();
    BluetoothService? cubechatService;
    for (final s in services) {
      if (s.uuid.str.toLowerCase() == BleConstants.serviceUuid.toLowerCase()) {
        cubechatService = s;
        break;
      }
    }
    if (cubechatService == null) {
      await disconnect();
      throw StateError('peer does not expose the cubechat service');
    }

    for (final ch in cubechatService.characteristics) {
      final uuid = ch.uuid.str.toLowerCase();
      if (uuid == BleConstants.inboundCharUuid.toLowerCase()) {
        _inbound = ch;
      } else if (uuid == BleConstants.outboundCharUuid.toLowerCase()) {
        _outbound = ch;
      } else if (uuid == BleConstants.peerInfoCharUuid.toLowerCase()) {
        _peerInfo = ch;
      }
    }

    if (_inbound == null || _outbound == null) {
      await disconnect();
      throw StateError('peer is missing the cubechat characteristics');
    }

    await _inbound!.setNotifyValue(true);
    _inboundSub = _inbound!.onValueReceived.listen((bytes) {
      if (bytes.isEmpty) return;
      _frames.add(Uint8List.fromList(bytes));
    });
  }

  /// Writes one frame to the peer's outbound characteristic.
  Future<void> writeOutbound(Uint8List bytes) async {
    final ch = _outbound;
    if (ch == null) {
      throw StateError('outbound characteristic not ready');
    }
    // Write-without-response is fire-and-forget; faster, no ack. For
    // handshake frames we want acked delivery, so we use the default
    // write-with-response.
    await ch.write(bytes, withoutResponse: false);
  }

  Future<void> disconnect() async {
    _running = false;
    await _inboundSub?.cancel();
    _inboundSub = null;
    await _connectionSub?.cancel();
    _connectionSub = null;
    try {
      await _device.disconnect();
    } catch (_) {
      // ignore — may already be disconnected.
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await _frames.close();
    await _connection.close();
  }
}
