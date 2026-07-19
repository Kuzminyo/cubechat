import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/core/ble/ble_constants.dart';
import 'package:cubechat/core/ble/ble_peripheral.dart';
import 'package:cubechat/core/transport/frame.dart';
import 'package:cubechat/core/transport/frame_fragment.dart';
import 'package:cubechat/core/transport/messaging_service.dart';
import 'package:cubechat/features/peers/data/peripheral_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A peripheral we can push inbound writes through by hand.
class _FakePeripheral implements BlePeripheral {
  final _events = StreamController<PeripheralEvent>.broadcast();
  final notified = <Uint8List>[];

  void emit(PeripheralEvent e) => _events.add(e);

  @override
  Stream<PeripheralEvent> events() => _events.stream;

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<bool> start({required String peerName, String? pubkeyFingerprint}) async => true;

  @override
  Future<void> stop() async {}

  @override
  Future<bool> notifyInbound(Uint8List data) async {
    notified.add(data);
    return true;
  }

  Future<void> dispose() => _events.close();
}

void main() {
  late Directory tempDir;
  late _FakePeripheral peripheral;
  late ProviderContainer container;
  late List<String> logged;
  late DebugPrintCallback originalDebugPrint;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_frag_test_');
    Hive.init(tempDir.path);
    SharedPreferences.setMockInitialValues({});

    logged = [];
    originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logged.add(message);
    };

    peripheral = _FakePeripheral();
    container = ProviderContainer(
      overrides: [blePeripheralProvider.overrideWithValue(peripheral)],
    );
    // Constructing the service is what wires its peripheral-event listener.
    container.read(messagingServiceProvider);
  });

  tearDown(() async {
    debugPrint = originalDebugPrint;
    container.dispose();
    // The service's dispose is async and Riverpod doesn't await it; give it a
    // turn to let go of its Hive boxes before closing them underneath it.
    await Future<void>.delayed(Duration.zero);
    await peripheral.dispose();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps the Hive files briefly locked after close; the temp dir
      // is the OS's problem at that point, not the test's.
    }
  });

  /// Let the service's async event handling settle.
  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('inbound fragments on the peripheral side', () {
    // Regression: the peripheral path decoded each write and dispatched it
    // directly, skipping the reassembly that the central path did. Every frame
    // a peer had to fragment for the link MTU was therefore dropped on arrival
    // — silently, and only when this device happened to be the peripheral.
    // Field logs showed the pair: an "RX fragment ... (peripheral side)"
    // immediately followed by "unexpected fragment frame at dispatch".
    test('are reassembled instead of dropped at dispatch', () async {
      const centralId = 'central-1';
      // A frame comfortably larger than a small link MTU, so it must split.
      final whole = Frame(
        type: FrameType.noiseHandshake1,
        payload: Uint8List.fromList(List.generate(300, (i) => i & 0xFF)),
      ).encode();
      final parts = fragmentFrame(whole, 120);
      expect(parts.length, greaterThan(1),
          reason: 'test frame must actually fragment to be meaningful');

      for (final p in parts) {
        peripheral.emit(PeripheralWrite(
            centralId: centralId,
            charUuid: BleConstants.outboundCharUuid,
            data: p));
        await settle();
      }

      expect(
        logged.where((l) => l.contains('unexpected fragment frame at dispatch')),
        isEmpty,
        reason: 'fragments must be rejoined before dispatch, not dropped',
      );
      // The reassembled frame reached dispatch as its original type.
      expect(
        logged.where((l) =>
            l.contains('RX noiseHandshake1') && l.contains('peripheral side')),
        isNotEmpty,
        reason: 'the rejoined frame should be dispatched on the peripheral side',
      );
    });

    test('an unfragmented frame still dispatches directly', () async {
      const centralId = 'central-2';
      final whole = Frame(
        type: FrameType.noiseHandshake1,
        payload: Uint8List.fromList(List.generate(32, (i) => i & 0xFF)),
      ).encode();
      // Small enough that fragmentFrame would pass it through untouched.
      expect(fragmentFrame(whole, 120), hasLength(1));

      peripheral.emit(PeripheralWrite(
          centralId: centralId,
          charUuid: BleConstants.outboundCharUuid,
          data: whole));
      await settle();

      expect(
        logged.where((l) =>
            l.contains('RX noiseHandshake1') && l.contains('peripheral side')),
        isNotEmpty,
      );
    });
  });
}
