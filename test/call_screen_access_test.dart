import 'package:cubechat/core/util/app_build.dart';
import 'package:cubechat/features/call/data/call_screen_access.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Тумблер дзвінків на екрані блокування скидається після оновлення" — on
/// every phone, and off in the system settings too. Android takes the
/// full-screen permission back when an APK from outside Google Play is
/// installed over itself; no app can grant it back. So the app notices, and
/// asks once.
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

  Future<CallScreenAccess> read(Map<String, Object> stored) async {
    SharedPreferences.setMockInitialValues(stored);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(callScreenAccessProvider.notifier).refresh();
    return container.read(callScreenAccessProvider);
  }

  test('on in an earlier build and off now: an update took it, so ask',
      () async {
    final access = await read({
      CallScreenAccessController.grantedInBuildKey: 'an-earlier-build',
    });
    expect(access.complete, isFalse);
    expect(access.worthAsking, isTrue);
  });

  test('off in the same build it was on in: the person turned it off',
      () async {
    final access = await read({
      CallScreenAccessController.grantedInBuildKey: appBuildStamp,
    });
    expect(access.worthAsking, isFalse);
  });

  test('never recorded and never asked: ask, so the first update is covered',
      () async {
    // The build was not recorded before this code existed, so the very reset
    // that was reported would otherwise pass without a word.
    final access = await read({});
    expect(access.worthAsking, isTrue);
  });

  test('asked once, it is not asked again until an update takes it again',
      () async {
    SharedPreferences.setMockInitialValues({
      CallScreenAccessController.grantedInBuildKey: 'an-earlier-build',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(callScreenAccessProvider.notifier);
    await notifier.refresh();
    expect(container.read(callScreenAccessProvider).worthAsking, isTrue);

    await notifier.acknowledgeAsked();
    await notifier.refresh();
    expect(container.read(callScreenAccessProvider).worthAsking, isFalse);

    // Turned back on: remembered against this build, so the next update that
    // takes it away is noticed again.
    granted = true;
    await notifier.refresh();
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(CallScreenAccessController.grantedInBuildKey),
      appBuildStamp,
    );
  });

  test('on: nothing to ask, and this build is remembered', () async {
    granted = true;
    final access = await read({});
    expect(access.complete, isTrue);
    expect(access.worthAsking, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(CallScreenAccessController.grantedInBuildKey),
      appBuildStamp,
    );
  });
}
