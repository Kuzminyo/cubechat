import 'dart:io';

import 'package:cubechat/core/util/platform_capabilities.dart';
import 'package:cubechat/features/profile/data/nav_bar_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/hive_settle.dart';

/// One answer to "what can this platform do", so a Windows build hides what a
/// computer has no hardware or library for — Bluetooth, the map, the camera,
/// calls, on-device translation, the phone's gallery — in one place.
void main() {
  test('a phone can do everything, a computer none of the mobile things', () {
    for (final p in [TargetPlatform.android, TargetPlatform.iOS]) {
      final c = PlatformCapabilities.forPlatform(p);
      expect(
        [
          c.bluetooth, c.maps, c.googleMaps, c.shareLocation, c.camera,
          c.calls, c.translation, c.gallery,
        ],
        everyElement(isTrue),
        reason: '$p',
      );
    }
    for (final p in [
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      final c = PlatformCapabilities.forPlatform(p);
      expect(
        [
          c.bluetooth, c.googleMaps, c.shareLocation, c.camera,
          c.translation, c.gallery,
        ],
        everyElement(isFalse),
        reason: '$p',
      );
      expect(c.maps, isTrue, reason: '$p draws the map from tiles, to look');
    }
  });

  test('calls on Windows, where the WebRTC library is shipped, and nowhere '
      'else on a computer', () {
    expect(PlatformCapabilities.forPlatform(TargetPlatform.windows).calls,
        isTrue);
    expect(
        PlatformCapabilities.forPlatform(TargetPlatform.macOS).calls, isFalse);
    expect(
        PlatformCapabilities.forPlatform(TargetPlatform.linux).calls, isFalse);
    expect(
      PlatformCapabilities.forPlatform(TargetPlatform.windows, web: true).calls,
      isFalse,
    );
    expect(
      PlatformCapabilities.forPlatform(TargetPlatform.android, web: true)
          .bluetooth,
      isFalse,
    );
  });

  group('the tab bar on a computer', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cubechat_caps_');
      Hive.init(tempDir.path);
      SharedPreferences.setMockInitialValues({});
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

    ProviderContainer desktop() {
      final c = ProviderContainer(
        overrides: [
          platformCapabilitiesProvider.overrideWithValue(
            PlatformCapabilities.forPlatform(TargetPlatform.windows),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('has no Nearby, and does not offer it back', () {
      final c = desktop();
      final layout = c.read(navBarControllerProvider);
      expect(layout.shown, isNot(contains(NavDestination.peers)));
      expect(layout.shown.first, NavDestination.chats);
      expect(layout.hidden, isNot(contains(NavDestination.peers)));
    });

    test('has the Map, asked for on 2026-10-12', () {
      final c = desktop();
      final layout = c.read(navBarControllerProvider);
      expect(
        [...layout.shown, ...layout.hidden],
        contains(NavDestination.map),
      );
    });

    test('putting Nearby back does nothing', () async {
      final c = desktop();
      await c.read(navBarControllerProvider.notifier).show(NavDestination.peers);
      expect(
        c.read(navBarControllerProvider).shown,
        isNot(contains(NavDestination.peers)),
      );
    });
  });
}
