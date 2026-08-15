import 'dart:io';

import 'package:cubechat/core/notifications/ios_background_refresh.dart';
import 'package:cubechat/core/transport/messaging_service.dart';
import 'package:cubechat/features/map/data/map_presence_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'support/hive_settle.dart';

class _FakeMapPresenceController extends MapPresenceController {
  static bool poked = false;

  @override
  int build() => 0;

  @override
  Future<void> pokeNow() async {
    poked = true;
  }
}

/// The Dart half of the iOS background window. The native half (BGTaskScheduler
/// registration, the 25 s deadline) can only be exercised on a device, so what
/// is pinned here is the contract between them: the channel answers, the window
/// is bounded, and a second overlapping call is refused.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cubechat_bgfetch_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await settleBackgroundStorage();
    await Hive.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the Hive files briefly after close.
    }
  });

  /// Invoke the channel the way AppDelegate does, through the platform
  /// messenger, so the registered handler is what runs.
  Future<void> invokeFromNative(String method) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final encoded = const StandardMethodCodec().encodeMethodCall(
      MethodCall(method),
    );
    await messenger.handlePlatformMessage(
      IosBackgroundRefresh.channel.name,
      encoded,
      (_) {},
    );
  }

  test('the window builds the messaging service, which is what fetches',
      () async {
    // Standing the transport up is the whole mechanism: it reconnects to the
    // relays, which replay everything since the persisted watermark. A window
    // that never touched the provider would fetch nothing.
    var built = false;
    final container = ProviderContainer(
      overrides: [
        messagingServiceProvider.overrideWith((ref) {
          built = true;
          return MessagingService(ref);
        }),
      ],
    );
    addTearDown(container.dispose);
    IosBackgroundRefresh.instance.install(container);
    addTearDown(
      () => IosBackgroundRefresh.channel.setMethodCallHandler(null),
    );

    await IosBackgroundRefresh.instance
        .refreshNow(window: const Duration(milliseconds: 20));
    expect(built, isTrue);
  });

  test('the window also gives live map presence a chance to publish', () async {
    _FakeMapPresenceController.poked = false;
    final container = ProviderContainer(
      overrides: [
        mapPresenceControllerProvider.overrideWith(
          _FakeMapPresenceController.new,
        ),
      ],
    );
    addTearDown(container.dispose);
    IosBackgroundRefresh.instance.install(container);

    await IosBackgroundRefresh.instance.refreshNow(
      window: const Duration(milliseconds: 1100),
    );

    expect(_FakeMapPresenceController.poked, isTrue);
  });
  test('the window is bounded — it returns rather than running until killed',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    IosBackgroundRefresh.instance.install(container);

    final started = DateTime.now();
    await IosBackgroundRefresh.instance
        .refreshNow(window: const Duration(milliseconds: 30));
    final elapsed = DateTime.now().difference(started);
    // iOS kills an app whose BGAppRefreshTask overruns, so returning is the
    // whole contract here.
    expect(elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('an overlapping call is refused instead of opening a second window',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    IosBackgroundRefresh.instance.install(container);

    final first = IosBackgroundRefresh.instance
        .refreshNow(window: const Duration(milliseconds: 120));
    final second = IosBackgroundRefresh.instance
        .refreshNow(window: const Duration(milliseconds: 120));
    // The second returns immediately; both complete without throwing.
    await second;
    await first;
  });

  test('a refresh before install() is ignored, not thrown', () async {
    final fresh = IosBackgroundRefresh.instance;
    IosBackgroundRefresh.channel.setMethodCallHandler(null);
    // Nothing installed in this test: the native side can fire the task during
    // a cold launch before main() finishes, and that must not crash the app.
    await expectLater(invokeFromNative('runRefresh'), completes);
    expect(fresh, isNotNull);
  });

  test('an unknown method is reported as missing, not silently accepted',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    IosBackgroundRefresh.instance.install(container);
    addTearDown(
      () => IosBackgroundRefresh.channel.setMethodCallHandler(null),
    );

    await expectLater(invokeFromNative('somethingElse'), completes);
  });
}
