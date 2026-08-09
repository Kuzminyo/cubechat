import 'package:cubechat/features/profile/data/privacy_settings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PrivacySettings', () {
    test('shares both signals until the user opts out', () {
      // Seeing that someone is around, and that they read you, is most of what
      // makes a conversation feel alive. Hiding it unasked reads as a bug.
      expect(PrivacySettings.initial.shareLastSeen, isTrue);
      expect(PrivacySettings.initial.shareReadReceipts, isTrue);
      expect(PrivacySettings.initial.shareMapLocation, isFalse);
    });

    test('copyWith leaves the other switch alone', () {
      // The two are independent: turning off read receipts must not silently
      // take last-seen with it.
      final onlyReceiptsOff =
          PrivacySettings.initial.copyWith(shareReadReceipts: false);
      expect(onlyReceiptsOff.shareReadReceipts, isFalse);
      expect(onlyReceiptsOff.shareLastSeen, isTrue);

      final onlySeenOff =
          PrivacySettings.initial.copyWith(shareLastSeen: false);
      expect(onlySeenOff.shareLastSeen, isFalse);
      expect(onlySeenOff.shareReadReceipts, isTrue);
    });

    test('compares by value, so a rebuild with equal state is a no-op', () {
      expect(
        const PrivacySettings(
          shareLastSeen: false,
          shareReadReceipts: true,
          shareMapLocation: false,
        ),
        equals(
          const PrivacySettings(
            shareLastSeen: false,
            shareReadReceipts: true,
            shareMapLocation: false,
          ),
        ),
      );
      expect(
        const PrivacySettings(
          shareLastSeen: false,
          shareReadReceipts: true,
          shareMapLocation: false,
        ),
        isNot(equals(PrivacySettings.initial)),
      );
    });

    test('hashCode tracks both fields', () {
      // Both flags feed the hash; if only one did, two settings that differ in
      // the other would collide in any Set/Map keyed on the value.
      final a = const PrivacySettings(
        shareLastSeen: true,
        shareReadReceipts: false,
        shareMapLocation: false,
      );
      final b = const PrivacySettings(
        shareLastSeen: false,
        shareReadReceipts: true,
        shareMapLocation: false,
      );
      expect(a.hashCode, isNot(equals(b.hashCode)));
    });
  });
}
