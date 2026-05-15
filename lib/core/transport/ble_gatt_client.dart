import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../ble/ble_constants.dart';
import '../util/debug_log.dart';

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
  int _negotiatedMtu = 23;

  String get peerId => _device.remoteId.str;
  int get negotiatedMtu => _negotiatedMtu;
  Stream<Uint8List> get inboundFrames => _frames.stream;
  Stream<BluetoothConnectionState> get connectionState => _connection.stream;
  bool get isConnected =>
      _device.isConnected;

  /// Connects to the device, discovers our service, finds the characteristics,
  /// and subscribes to inbound notifications. Throws if any step fails.
  Future<void> connect({Duration timeout = const Duration(seconds: 8)}) async {
    if (_running) return;
    _running = true;

    final log = DebugLog.instance;
    log.log('BLE-CENTRAL', 'connect → ${_device.remoteId.str}');

    _connectionSub = _device.connectionState.listen((s) {
      _connection.add(s);
      log.log('BLE-CENTRAL', 'state=$s');
      if (s == BluetoothConnectionState.disconnected) {
        _running = false;
      }
    });

    await _device.connect(timeout: timeout, autoConnect: false);
    log.log('BLE-CENTRAL', 'connected, requesting MTU ${BleConstants.preferredMtu}');

    try {
      _negotiatedMtu = await _device.requestMtu(BleConstants.preferredMtu);
      log.log('BLE-CENTRAL', 'MTU negotiated = $_negotiatedMtu');
    } catch (e) {
      log.log('BLE-CENTRAL', 'requestMtu failed: $e — staying at default 23');
    }

    log.log('BLE-CENTRAL', 'discoverServices…');
    final services = await _device.discoverServices();
    log.log('BLE-CENTRAL', 'discovered ${services.length} services');
    BluetoothService? cubechatService;
    for (final s in services) {
      if (s.uuid.str.toLowerCase() == BleConstants.serviceUuid.toLowerCase()) {
        cubechatService = s;
        break;
      }
    }
    if (cubechatService == null) {
      DebugLog.instance.log('BLE-CENTRAL', 'cubechat service NOT FOUND on peer');
      await disconnect();
      throw StateError('peer does not expose the cubechat service');
    }
    DebugLog.instance.log('BLE-CENTRAL', 'cubechat service found, '
        '${cubechatService.characteristics.length} characteristics');

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
      DebugLog.instance.log('BLE-CENTRAL', 'characteristics missing: '
          'inbound=${_inbound != null} outbound=${_outbound != null}');
      await disconnect();
      throw StateError('peer is missing the cubechat characteristics');
    }

    DebugLog.instance.log('BLE-CENTRAL', 'subscribing to inbound notifications…');
    final subscribed = await _inbound!.setNotifyValue(true);
    DebugLog.instance.log('BLE-CENTRAL',
        'setNotifyValue returned $subscribed (true means CCCD write acked)');
    _inboundSub = _inbound!.onValueReceived.listen((bytes) {
      if (bytes.isEmpty) return;
      DebugLog.instance.log('BLE-CENTRAL', 'inbound notify (${bytes.length}B)');
      _frames.add(Uint8List.fromList(bytes));
    });
    DebugLog.instance.log('BLE-CENTRAL', 'ready');
  }

  /// Writes one frame to the peer's outbound characteristic.
  Future<void> writeOutbound(Uint8List bytes) async {
    final ch = _outbound;
    if (ch == null) {
      throw StateError('outbound characteristic not ready');
    }
    DebugLog.instance.log('BLE-CENTRAL', 'write ${bytes.length}B → outbound');
    try {
      await ch.write(bytes, withoutResponse: false);
      DebugLog.instance.log('BLE-CENTRAL', 'write OK');
    } catch (e) {
      DebugLog.instance.log('BLE-CENTRAL', 'write FAILED: $e');
      rethrow;
    }
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
