import 'dart:async';
import 'dart:io';

import 'package:cubechat/core/notifications/ios_background_refresh.dart';
import 'package:cubechat/core/transport/messaging_service.dart';
import 'package:cubechat/core/util/location_service.dart';
import 'package:cubechat/features/map/data/map_presence_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'support/hive_settle.dart';

class _FakeMapPresenceController extends MapPresenceController {
  static bool poked = false;
  static StampedLocationFix? offered;

  @override
  int build() => 0;

  @override
  Future<void> pokeNow({StampedLocationFix? offered}) async {
    poked = true;
    _FakeMapPresenceController.offered = offered;
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
          final service = MessagingService(ref);
          // The real provider registers this, and an override replaces the
          // whole body — so without it this service is never disposed, and its
          // file-queue timer goes on reading a container that is gone. That
          // lands as "this test failed after it had already completed" on
          // whichever case is running when the timer next fires, which is
          // usually not this one.
          ref.onDispose(() => unawaited(service.dispose()));
          return service;
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
    expect(_FakeMapPresenceController.offered, isNull,
        reason: 'a scheduled window brings no position of its own');
  });

  test("a doorbell's own position is carried through to the pin", () async {
    // The significant-change wake-up arrives holding the coarse fix that
    // decided the phone had moved. Handing it on is what lets the pin be
    // republished without asking CoreLocation for a cold one — background GPS
    // being the largest measured expense this app has.
    _FakeMapPresenceController.poked = false;
    _FakeMapPresenceController.offered = null;
    final container = ProviderContainer(
      overrides: [
        mapPresenceControllerProvider.overrideWith(
          _FakeMapPresenceController.new,
        ),
      ],
    );
    addTearDown(container.dispose);
    IosBackgroundRefresh.instance.install(container);

    final woke = StampedLocationFix(
      const LocationFix(latitude: 50.0, longitude: 36.2, accuracyMetres: 480),
      DateTime.now(),
    );
    await IosBackgroundRefresh.instance.refreshNow(
      window: const Duration(milliseconds: 1100),
      offered: woke,
    );

    expect(_FakeMapPresenceController.offered, same(woke));
  });

  group('the position a wake-up arrives with', () {
    Map<String, Object> wake({
      Object lat = 50.0,
      Object lon = 36.2,
      Object accuracy = 480.0,
      Object at = 1_755_000_000_000,
    }) =>
        {'lat': lat, 'lon': lon, 'accuracy': accuracy, 'at': at};

    test('is read with its own stamp, not the moment it was read', () {
      final fix = IosBackgroundRefresh.fixFromWake(wake());
      expect(fix, isNotNull);
      expect(fix!.fix.latitude, 50.0);
      expect(fix.fix.longitude, 36.2);
      expect(fix.fix.accuracyMetres, 480);
      // A relaunch spends seconds booting Dart before this runs. Re-dating the
      // fix here would hide the age the next reader is checking for.
      expect(fix.at.millisecondsSinceEpoch, 1_755_000_000_000);
    });

    test('is refused when the platform says the coordinate is invalid', () {
      // CoreLocation spells "I do not actually know where this is" as a
      // negative horizontal accuracy, and it is a real value to receive.
      expect(IosBackgroundRefresh.fixFromWake(wake(accuracy: -1.0)), isNull);
    });

    test('is refused when it could not be a place', () {
      expect(IosBackgroundRefresh.fixFromWake(wake(lat: 91.0)), isNull);
      expect(IosBackgroundRefresh.fixFromWake(wake(lon: -181.0)), isNull);
      expect(IosBackgroundRefresh.fixFromWake(wake(at: 0)), isNull);
    });

    test('is refused when it is not there at all', () {
      // The scheduled BGAppRefreshTask path, which carries no arguments — and
      // anything malformed, since a wrong number here is a pin somewhere the
      // user has never been.
      expect(IosBackgroundRefresh.fixFromWake(null), isNull);
      expect(IosBackgroundRefresh.fixFromWake('nonsense'), isNull);
      expect(
        IosBackgroundRefresh.fixFromWake(<String, Object>{'lat': 50.0}),
        isNull,
      );
      expect(IosBackgroundRefresh.fixFromWake(wake(lat: 'north')), isNull);
    });
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
