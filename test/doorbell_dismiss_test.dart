import 'package:cubechat/core/notifications/notification_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// "Нове повідомлення" with nothing behind it.
///
/// The push service rings on seeing an event addressed to this phone and can
/// read none of it, so it rings for things the app has nothing to show about:
/// a message that already arrived over Bluetooth, a room frame this phone is
/// not a member of, a copy of something already stored. The banner then stood
/// on the lock screen with nothing behind it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('cubechat/push');
  late List<String> calls;

  setUp(() {
    calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    NotificationService.instance.debugLastShownAt = null;
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    NotificationService.instance.debugLastShownAt = null;
  });

  test('nothing shown: the banner comes down', () async {
    await NotificationService.instance.dismissStaleDoorbell();
    expect(calls, ['dismissDoorbell']);
  });

  test('a notification of our own just went up: it stays', () async {
    NotificationService.instance.debugLastShownAt = DateTime.now();
    await NotificationService.instance.dismissStaleDoorbell();
    expect(
      calls,
      isEmpty,
      reason: 'the banner standing there is the one the app itself raised',
    );
  });

  test('an old one does not hold it', () async {
    NotificationService.instance.debugLastShownAt =
        DateTime.now().subtract(const Duration(minutes: 5));
    await NotificationService.instance.dismissStaleDoorbell();
    expect(calls, ['dismissDoorbell']);
  });

  test('opening the app takes it down whatever was shown', () async {
    NotificationService.instance.debugLastShownAt = DateTime.now();
    await NotificationService.instance
        .dismissStaleDoorbell(within: Duration.zero);
    expect(calls, ['dismissDoorbell']);
  });
}
