import 'package:cubechat/features/profile/data/dead_mans_switch_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final noon = DateTime(2026, 8, 25, 12);

  test('off by default, and off is off', () {
    const off = DeadMansSwitch();
    expect(off.enabled, isFalse);
    // Even years later. A switch nobody armed must never fire.
    expect(off.hasExpired(DateTime(2030)), isFalse);
  });

  test('does not fire before it has ever seen the app opened', () {
    // Otherwise the install that arms it is already past its own deadline,
    // and the wipe lands on the person setting it up.
    const armed = DeadMansSwitch(days: 7);
    expect(armed.lastOpened, isNull);
    expect(armed.hasExpired(DateTime(2030)), isFalse);
  });

  test('fires only once the silence is longer than the setting', () {
    final armed = DeadMansSwitch(days: 7, lastOpened: noon);

    expect(armed.hasExpired(noon.add(const Duration(days: 6, hours: 23))),
        isFalse);
    expect(armed.hasExpired(noon.add(const Duration(days: 7))), isTrue);
    expect(armed.hasExpired(noon.add(const Duration(days: 30))), isTrue);
  });

  test('a clock that went backwards does not fire it', () {
    final armed = DeadMansSwitch(days: 7, lastOpened: noon);
    expect(armed.hasExpired(noon.subtract(const Duration(days: 30))), isFalse);
  });

  test('a week is the shortest anyone may choose', () {
    // Shorter than this and an ordinary holiday, a hospital stay or a flat
    // battery costs somebody every message they have.
    final armable = DeadMansSwitchController.choices.where((d) => d > 0);
    expect(armable.reduce((a, b) => a < b ? a : b), 7);
    expect(DeadMansSwitchController.choices, contains(0));
  });
}
