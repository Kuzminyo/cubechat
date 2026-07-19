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
  StreamSubscription<int>? _mtuSub;

  final _frames = StreamController<Uint8List>.broadcast();
  final _connection = StreamController<BluetoothConnectionState>.broadcast();

  bool _running = false;
  int _negotiatedMtu = 23;

  /// True once the platform has reported a real ATT MTU for this link, as
  /// opposed to us still sitting on the 23-byte assumption.
  bool _mtuKnown = false;

  /// Serialises [writeOutbound] across all callers — concurrent writes on the
  /// same characteristic make flutter_blue_plus silently drop frames on some
  /// stacks. Image chunking + announcement broadcasts can otherwise collide
  /// mid-stream and lose data.
  Future<void> _writeChain = Future<void>.value();

  String get peerId => _device.remoteId.str;

  /// The link's real ATT MTU, read live from the platform on every access.
  ///
  /// It cannot be latched at connect time, and it cannot be taken from
  /// [BluetoothDevice.requestMtu] alone:
  ///
  ///  * `requestMtu` is Android-only. On iOS it throws, and we used to swallow
  ///    that and leave the field at the 23-byte ATT default — so every frame
  ///    an iPhone sent as central was fragmented into 13-byte slices: a 174 B
  ///    announce went out as 14 writes, and a 10 KB voice note as ~3300
  ///    instead of the 91 the same note took in the Android→iOS direction.
  ///    CoreBluetooth negotiates the MTU itself (185+ in practice); the plugin
  ///    polls for it and reports it through [BluetoothDevice.mtuNow].
  ///  * iOS reports it *after* the connect completes, so a value read once at
  ///    the end of [connect] can still be the stale 23.
  ///
  /// [mtuNow] falls back to 23 when the platform hasn't reported yet, so keep
  /// whichever value is larger: on Android the `requestMtu` result is
  /// authoritative the moment it returns.
  int get negotiatedMtu {
    final live = _device.mtuNow;
    return live > _negotiatedMtu ? live : _negotiatedMtu;
  }

  Stream<Uint8List> get inboundFrames => _frames.stream;
  Stream<BluetoothConnectionState> get connectionState => _connection.stream;
  bool get isConnected =>
      _device.isConnected;

  /// Connects to the device, discovers our service, finds the characteristics,
  /// and subscribes to inbound notifications. Throws if any step fails.
  Future<void> connect({Duration timeout = const Duration(seconds: 8)}) async {
    if (_running) return;
    _running = true;
    try {
      await _connect(timeout);
    } catch (_) {
      // A failed connect must not leave the client half-alive: the
      // connectionState subscription is opened before the GATT connect can
      // fail, and _running would otherwise stay latched so a later retry on
      // this object would early-return as if already connected.
      _running = false;
      await _inboundSub?.cancel();
      _inboundSub = null;
      await _connectionSub?.cancel();
      _connectionSub = null;
      await _mtuSub?.cancel();
      _mtuSub = null;
      rethrow;
    }
  }

  Future<void> _connect(Duration timeout) async {
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

    // Track every MTU the platform reports for the life of the link. This is
    // the only channel that carries iOS's self-negotiated value, and it also
    // catches a late renegotiation on Android.
    _mtuSub = _device.mtu.listen((m) {
      if (m <= _negotiatedMtu) return;
      _negotiatedMtu = m;
      _mtuKnown = true;
      log.log('BLE-CENTRAL', 'MTU reported by platform = $m');
    });

    try {
      _negotiatedMtu = await _device.requestMtu(BleConstants.preferredMtu);
      _mtuKnown = true;
      log.log('BLE-CENTRAL', 'MTU negotiated = $_negotiatedMtu');
    } catch (e) {
      // Expected on iOS — CoreBluetooth owns MTU negotiation and refuses the
      // request. It reports the real value through the stream above shortly
      // after connecting, so give it a moment rather than sizing frames for
      // 23 bytes and crawling for the rest of the session.
      log.log('BLE-CENTRAL', 'requestMtu unavailable ($e) — awaiting the '
          "platform's own MTU report");
      await _awaitPlatformMtu();
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

  /// Waits briefly for the platform to report this link's MTU.
  ///
  /// iOS negotiates the MTU itself a moment after the connection is up, and
  /// the plugin discovers it by polling, so the value isn't there the instant
  /// [connect] returns. Blocking the handshake on it for a second or so buys
  /// correctly-sized frames from the very first write; if it never arrives we
  /// carry on at 23 and the [negotiatedMtu] getter picks the real value up as
  /// soon as it lands.
  Future<void> _awaitPlatformMtu({
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    if (_mtuKnown) return;
    try {
      final mtu = await _device.mtu.firstWhere((m) => m > 23).timeout(timeout);
      if (mtu > _negotiatedMtu) _negotiatedMtu = mtu;
      _mtuKnown = true;
      DebugLog.instance.log('BLE-CENTRAL', 'platform reported MTU = $mtu');
    } on TimeoutException {
      DebugLog.instance.log('BLE-CENTRAL',
          'no MTU report within ${timeout.inMilliseconds}ms — sizing frames '
          'for 23 until one arrives');
    }
  }

  /// Writes one frame to the peer's outbound characteristic. Calls are
  /// serialised — concurrent writes (image chunking + periodic announcements,
  /// for instance) would otherwise race in the native BLE stack and silently
  /// drop frames on cheap Android adapters. One transient failure is
  /// retried once with a short back-off before the error propagates.
  Future<void> writeOutbound(Uint8List bytes) async {
    final ch = _outbound;
    if (ch == null) {
      throw StateError('outbound characteristic not ready');
    }
    // Chain this write behind any in-flight one; ignore any prior error so
    // a single failure doesn't poison every subsequent send on this link.
    final next = _writeChain.catchError((_) {}).then(
      (_) => _writeWithRetry(ch, bytes),
    );
    _writeChain = next;
    return next;
  }

  static Future<void> _writeWithRetry(
    BluetoothCharacteristic ch,
    Uint8List bytes,
  ) async {
    // Verbose per-write logging gets buried under chunked media (an image
    // is hundreds of writes, a video circle thousands) and washes more
    // useful debug logs out of the in-memory ring buffer. Log only on
    // failure — success is implied by absence of a FAILED line.
    try {
      await ch.write(bytes, withoutResponse: false);
      return;
    } catch (e) {
      DebugLog.instance.log('BLE-CENTRAL',
          'write ${bytes.length}B FAILED ($e) — retrying once');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      try {
        await ch.write(bytes, withoutResponse: false);
        DebugLog.instance.log('BLE-CENTRAL',
            'write ${bytes.length}B OK (retry)');
      } catch (e2) {
        DebugLog.instance.log('BLE-CENTRAL',
            'write ${bytes.length}B FAILED again: $e2');
        rethrow;
      }
    }
  }

  Future<void> disconnect() async {
    _running = false;
    await _inboundSub?.cancel();
    _inboundSub = null;
    await _connectionSub?.cancel();
    _connectionSub = null;
    await _mtuSub?.cancel();
    _mtuSub = null;
    // The platform drops its cached MTU on disconnect; drop ours too, so a
    // reconnect can't size frames for the previous link's ceiling.
    _negotiatedMtu = 23;
    _mtuKnown = false;
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
