import 'dart:io';

import 'package:cubechat/core/storage/hive_cipher.dart';
import 'package:cubechat/core/storage/hive_init.dart';
import 'package:cubechat/features/profile/data/relay_settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

void main() {
  group('relay URL validation', () {
    test('accepts ws:// and wss:// endpoints', () {
      expect(
        RelaySettingsController.isValidRelayUrl('wss://relay.damus.io'),
        isTrue,
      );
      expect(
        RelaySettingsController.isValidRelayUrl('ws://localhost:7777'),
        isTrue,
      );
    });

    test('rejects anything that is not a WebSocket endpoint', () {
      // An https:// URL would silently never connect; a bare host has no
      // scheme to dial. Both must be caught at the input field, not at runtime.
      for (final bad in [
        'https://relay.damus.io',
        'relay.damus.io',
        'wss://',
        '',
        'not a url',
      ]) {
        expect(
          RelaySettingsController.isValidRelayUrl(bad),
          isFalse,
          reason: 'should reject "$bad"',
        );
      }
    });
  });

  group('RelaySettings', () {
    test('is inactive until the user opts in', () {
      // The fallback touches a server; cubechat's promise is that it doesn't
      // have to. So the default must be off.
      expect(RelaySettings.initial.enabled, isFalse);
      expect(RelaySettings.initial.isActive, isFalse);
    });

    test('enabled with no relays is still inactive', () {
      const settings = RelaySettings(enabled: true, urls: []);
      expect(settings.isActive, isFalse);
    });

    test('enabled with relays is active', () {
      const settings =
          RelaySettings(enabled: true, urls: ['wss://relay.damus.io']);
      expect(settings.isActive, isTrue);
    });
  });

  group('a relay added to the defaults reaches a phone that already has a list',
      () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cubechat_relays_');
      Hive.init(tempDir.path);
    });

    tearDown(() async {
      await settleBackgroundStorage();
      await Hive.close();
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows holds the encrypted box briefly after close.
      }
    });

    /// What an install from before the change looks like on disk: the two
    /// relays that were stock then, and no record of the addition.
    Future<void> seedOldInstall(List<String> urls) async {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      await box.put('nostr.enabled', true);
      await box.put('nostr.relays', urls);
    }

    test('the third is folded into a saved list of two', () async {
      // The whole reason this migration exists. A stored list wins over the
      // defaults, and merely switching the fallback on writes one — so every
      // phone that has ever used the relay screen keeps its two, and changing
      // `defaultUrls` alone would have reached nobody who reported delivery
      // resting on a single road.
      await seedOldInstall(const ['wss://nos.lol', 'wss://relay.primal.net']);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(relaySettingsProvider);
      await settleBackgroundStorage();

      expect(
        container.read(relaySettingsProvider).urls,
        containsAll(RelaySettings.defaultUrls),
      );
    });

    test('it is applied once, so a deliberate removal sticks', () async {
      await seedOldInstall(const ['wss://nos.lol', 'wss://relay.primal.net']);

      var container = ProviderContainer();
      container.read(relaySettingsProvider);
      await settleBackgroundStorage();
      // Asserted before removing it: without this the test passes just as well
      // when the migration never ran, because then there is nothing to remove
      // and nothing to come back.
      expect(
        container.read(relaySettingsProvider).urls,
        contains('wss://nostr.mom'),
        reason: 'the migration has to have added it for this to mean anything',
      );
      // Somebody looks at the new relay and decides against it.
      await container
          .read(relaySettingsProvider.notifier)
          .removeRelay('wss://nostr.mom');
      await settleBackgroundStorage();
      container.dispose();

      container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(relaySettingsProvider);
      await settleBackgroundStorage();

      expect(
        container.read(relaySettingsProvider).urls,
        isNot(contains('wss://nostr.mom')),
        reason: 'a migration that runs twice is a setting that cannot be unset',
      );
    });
  });
}
