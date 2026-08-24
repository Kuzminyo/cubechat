import 'package:cubechat/features/profile/data/quiet_hours_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// Hours in which the phone stays quiet. Muting is per chat and answers "not
/// this person"; this answers "not now", and in a mesh app that matters more
/// than most — messages arrive whenever somebody wanders into range.
void main() {
  DateTime at(int hour, [int minute = 0]) =>
      DateTime(2026, 8, 24, hour, minute);

  test('off means never quiet, whatever the window says', () {
    const q = QuietHours(fromMinutes: 0, toMinutes: 24 * 60 - 1);
    expect(q.covers(at(3)), isFalse);
  });

  test('a night that crosses midnight is still one night', () {
    // The case almost every night is, and the one a naive `from <= now < to`
    // gets exactly backwards: 23:00 to 08:00 would be quiet for nobody.
    const q = QuietHours(
      enabled: true,
      fromMinutes: 23 * 60,
      toMinutes: 8 * 60,
    );
    expect(q.covers(at(23, 30)), isTrue);
    expect(q.covers(at(2)), isTrue);
    expect(q.covers(at(7, 59)), isTrue);
    expect(q.covers(at(8)), isFalse, reason: 'the end is exclusive');
    expect(q.covers(at(12)), isFalse);
    expect(q.covers(at(22, 59)), isFalse);
  });

  test('a window inside one day behaves the ordinary way', () {
    const q = QuietHours(
      enabled: true,
      fromMinutes: 13 * 60,
      toMinutes: 14 * 60,
    );
    expect(q.covers(at(13, 30)), isTrue);
    expect(q.covers(at(12, 59)), isFalse);
    expect(q.covers(at(14)), isFalse);
  });

  test('a zero-length night is not a whole day of silence', () {
    // Both ends dragged to the same time. Reading it as "always" would silence
    // the phone permanently for somebody who was only fiddling with a picker.
    const q = QuietHours(enabled: true, fromMinutes: 9 * 60, toMinutes: 9 * 60);
    expect(q.covers(at(9)), isFalse);
    expect(q.covers(at(3)), isFalse);
  });
}
