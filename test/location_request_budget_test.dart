import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cubechat/core/util/location_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('concurrent location consumers share one request and can retry', () async {
    const channel = MethodChannel('flutter.baseflow.com/geolocator');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final gate = Completer<bool>();
    var checks = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isLocationServiceEnabled') {
        checks++;
        return gate.future;
      }
      throw StateError('Unexpected ${call.method}');
    });
    final map = const LocationService().current();
    final beacon = const LocationService().current();
    expect(identical(map, beacon), isTrue);
    gate.complete(false);
    await Future.wait([map, beacon]);
    expect(checks, 1);
    await const LocationService().current();
    expect(checks, 2);
    messenger.setMockMethodCallHandler(channel, null);
  });
}
