import 'dart:io';

import 'package:cubechat/core/theme/launcher_icon_service.dart';
import 'package:cubechat/core/theme/theme_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// The home-screen icon follows the palette, and the launcher is touched only
/// when the icon it shows is not the one wanted.
///
/// That second rule is the one a phone pays for: start-up re-selects the saved
/// palette, and on Android every switch toggles launcher components — some
/// launchers drop a pinned shortcut whose component was toggled.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('cubechat/launcher_icon');

  group('which icon a palette gets', () {
    test('each of the eight built-in palettes has its own icon', () {
      for (final p in AppPalette.all) {
        expect(LauncherIconService.iconFor(p.id), p.id);
      }
      expect(
        LauncherIconService.icons.toSet(),
        AppPalette.all.map((p) => p.id).toSet(),
      );
    });

    test('the default palette maps to the fresh-install icon', () {
      expect(
        LauncherIconService.iconFor(AppPalette.emerald.id),
        LauncherIconService.defaultIcon,
      );
    });

    test('an unknown or broken id falls back to the default', () {
      expect(LauncherIconService.iconFor('from-a-later-build'), 'emerald');
      expect(LauncherIconService.iconFor('hue:'), 'emerald');
      expect(LauncherIconService.iconFor('hue:banana'), 'emerald');
    });

    test('a hue from the wheel gets the nearest coloured icon', () {
      String at(double h) => LauncherIconService.iconFor(AppPalette.hue(h).id);
      expect(at(150), 'emerald');
      expect(at(40), 'amber');
      expect(at(0), 'rose');
      expect(at(355), 'rose');
      expect(at(270), 'violet');
      expect(at(235), 'indigo');
      // Graphite is the colourless one: a saturated blue is not grey.
      expect(at(210), 'ocean');
      for (var h = 0; h < 360; h += 5) {
        expect(at(h.toDouble()), isNot('slate'), reason: 'hue $h');
      }
    });
  });

  group('when the launcher has to be switched', () {
    const needs = LauncherIconService.needsSwitch;

    test('exactly the wanted entry is left alone', () {
      expect(needs({'rose'}, 'rose'), isFalse);
    });

    test('the wrong entry, none, or two are all switched', () {
      expect(needs({'emerald'}, 'rose'), isTrue);
      expect(needs(<String>{}, 'emerald'), isTrue);
      expect(needs({'emerald', 'rose'}, 'rose'), isTrue);
      expect(needs({'emerald', 'rose'}, 'emerald'), isTrue);
    });

    test('a platform that cannot say is not guessed at', () {
      expect(needs(null, 'rose'), isFalse);
    });
  });

  group('ThemeController and the launcher', () {
    late Directory tempDir;
    late ProviderContainer container;
    late List<MethodCall> calls;
    late String shown;

    /// What the phone has enabled when that is not simply [shown]: none, or
    /// two after a switch cut off between its calls.
    List<String>? enabled;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cubechat_icon_test_');
      Hive.init(tempDir.path);
      calls = [];
      shown = 'emerald';
      enabled = null;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      ThemeController.launcherIconSettle = const Duration(milliseconds: 20);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'currentIcon':
            return shown;
          case 'enabledIcons':
            return enabled ?? [shown];
          case 'setIcon':
            shown = (call.arguments as Map<Object?, Object?>)['icon']! as String;
            enabled = null;
            return true;
        }
        return null;
      });
      container = ProviderContainer();
      // Let the controller finish loading the saved palette first: a load that
      // lands after a pick re-selects the stored one over it.
      await container.read(themeControllerProvider.notifier).loaded;
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
      ThemeController.launcherIconSettle = const Duration(milliseconds: 700);
      await settleBackgroundStorage();
      container.dispose();
      await Hive.close();
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows holds the Hive files briefly after close.
      }
    });

    List<String> sets() => [
          for (final c in calls)
            if (c.method == 'setIcon')
              (c.arguments as Map<Object?, Object?>)['icon']! as String,
        ];

    ThemeController theme() => container.read(themeControllerProvider.notifier);

    /// Picks [p] and waits out the settle delay and the platform's answer.
    Future<void> pick(AppPalette p) async {
      await theme().select(p);
      await Future<void>.delayed(ThemeController.launcherIconSettle * 2);
      await theme().launcherIconSettled;
    }

    test('choosing a palette switches the icon once', () async {
      await pick(AppPalette.rose);
      expect(sets(), ['rose']);
      expect(shown, 'rose');

      await pick(AppPalette.ocean);
      await pick(AppPalette.emerald);
      expect(sets(), ['rose', 'ocean', 'emerald']);
      // The platform is asked what it shows once, not before every switch.
      expect(calls.where((c) => c.method == 'enabledIcons'), hasLength(1));
    });

    test('a palette whose icon is already shown touches nothing', () async {
      // A start-up with Rose saved: the launcher already shows Rose.
      shown = 'rose';
      await pick(AppPalette.rose);
      expect(sets(), isEmpty);
    });

    test('a hue that lands on the icon already shown touches nothing',
        () async {
      await pick(AppPalette.violet);
      await pick(AppPalette.hue(272));
      expect(sets(), ['violet']);
    });

    test('dragging across the wheel switches the icon once, at the end',
        () async {
      // The hue strip selects on every frame of a drag; on iOS each switch
      // is a system alert.
      for (var h = 0; h <= 240; h += 8) {
        await theme().select(AppPalette.hue(h.toDouble()));
      }
      await Future<void>.delayed(ThemeController.launcherIconSettle * 2);
      await theme().launcherIconSettled;
      expect(sets(), ['indigo']);
    });

    test('a failed switch is asked about again rather than assumed', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'enabledIcons') return [shown];
        throw PlatformException(code: 'nope');
      });
      await pick(AppPalette.amber);
      await pick(AppPalette.slate);
      expect(calls.where((c) => c.method == 'enabledIcons'), hasLength(2));
      expect(sets(), ['amber', 'slate']);
    });

    test('a cold start with Emerald saved puts a stale icon right', () async {
      // A switch back to Emerald that died with the process: the phone still
      // shows Rose, and Emerald's start goes through no select.
      shown = 'rose';
      container.dispose();
      container = ProviderContainer();
      await theme().loaded;
      await Future<void>.delayed(ThemeController.launcherIconSettle * 2);
      await theme().launcherIconSettled;
      expect(sets(), ['emerald']);
    });

    test('a cold start that finds the launcher right touches nothing',
        () async {
      container.dispose();
      container = ProviderContainer();
      await theme().loaded;
      await Future<void>.delayed(ThemeController.launcherIconSettle * 2);
      await theme().launcherIconSettled;
      expect(sets(), isEmpty);
      expect(calls.where((c) => c.method == 'enabledIcons'), isNotEmpty);
    });

    test('a switch cut off halfway, two entries enabled, is finished',
        () async {
      // Below API 33: Rose was enabled, then the process died before
      // Emerald was disabled.
      shown = 'rose';
      enabled = ['emerald', 'rose'];
      await pick(AppPalette.rose);
      expect(sets(), ['rose']);
    });

    test('no entry enabled at all asks for the wanted one', () async {
      enabled = [];
      await pick(AppPalette.ocean);
      expect(sets(), ['ocean']);
    });

    test('a platform without enabledIcons falls back to currentIcon',
        () async {
      // iOS answers notImplemented to the new method.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'currentIcon':
            return shown;
          case 'setIcon':
            shown = (call.arguments as Map<Object?, Object?>)['icon']! as String;
            return true;
        }
        throw MissingPluginException();
      });
      await pick(AppPalette.amber);
      await pick(AppPalette.amber);
      expect(sets(), ['amber']);
      expect(calls.where((c) => c.method == 'currentIcon'), hasLength(1));
    });

    test('desktop builds never call the channel', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pick(AppPalette.fuchsia);
      expect(calls, isEmpty);
    });
  });
}
