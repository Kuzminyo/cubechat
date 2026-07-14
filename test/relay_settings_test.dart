import 'package:cubechat/features/profile/data/relay_settings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
