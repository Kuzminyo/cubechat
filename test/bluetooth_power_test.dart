import 'package:cubechat/core/ble/bluetooth_power.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('cubechat/bluetooth_power_test');

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('Android enable action delegates to the system channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      received = call;
      return true;
    });

    final enabled =
        await const BluetoothPower(channel: channel).requestEnable();

    expect(enabled, isTrue);
    expect(received?.method, 'requestEnable');
  });
}
