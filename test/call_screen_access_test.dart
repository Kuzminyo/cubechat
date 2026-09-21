import 'package:cubechat/features/call/data/call_screen_access.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The lock-screen call switch in Profile shows what Android says.
///
/// Android takes the full-screen permission back when an APK from outside
/// Google Play is installed over itself, and no app can grant it back. The
/// sheet that used to ask about it after each update is gone at the owner's
/// request; what is left has to be right: the switch reads the system, and
/// reads it again on the way back from the settings page it opens.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('cubechat/incoming_call');

  late bool granted;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    granted = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'access') {
        return <String, bool>{
          'fullScreenIntent': granted,
          'xiaomi': false,
          'xiaomiLockScreen': true,
        };
      }
      return true;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('off in the system reads as off', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(callScreenAccessProvider.notifier).refresh();
    expect(container.read(callScreenAccessProvider).complete, isFalse);
  });

  test('switched on in the settings, a refresh picks it up', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(callScreenAccessProvider.notifier);
    await notifier.refresh();
    expect(container.read(callScreenAccessProvider).complete, isFalse);

    granted = true;
    await notifier.refresh();
    expect(container.read(callScreenAccessProvider).complete, isTrue);
  });
}
