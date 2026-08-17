import 'package:cubechat/core/transport/ble_gatt_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Which failures the connect retry is allowed to give up on.
///
/// `connectAsInitiatorWithRetry` classifies by exception type: a [StateError]
/// means the peer answered, enumerated, and is not one of ours, so retrying is
/// futile and it rethrows at once. Everything else is transient and retried.
///
/// The bug this pins: an *empty* service list was also raised as a StateError,
/// so a race in the Android stack — both phones connecting to each other in the
/// same instant, one of them handed an empty list ten milliseconds later — was
/// classified as "this is not a cubechat device" and never retried. A person
/// pressing the retry button five times was doing the loop's job by hand.
void main() {
  group('BleDiscoveryFailed', () {
    test('is not a StateError, so the retry loop does not give up on it', () {
      const failure = BleDiscoveryFailed('4A:36:F6:0D:F1:D8');
      expect(
        failure,
        isNot(isA<StateError>()),
        reason: 'a StateError is the one class of failure that is never '
            'retried — an empty service list must not land there',
      );
      expect(failure, isA<Exception>());
    });

    test('says which link it was, and that the link itself was up', () {
      const failure = BleDiscoveryFailed('4A:36:F6:0D:F1:D8');
      final text = failure.toString();
      expect(text, contains('4A:36:F6:0D:F1:D8'));
      // The old message claimed the peer "does not expose the cubechat
      // service", which sent everyone looking at the wrong phone.
      expect(text, isNot(contains('does not expose')));
    });

    test('the permanent case is still a StateError', () {
      // Documented here rather than left implicit: the two failures are told
      // apart by type and nothing else, so if one of them ever changes class
      // the retry policy silently inverts.
      expect(
        StateError('peer does not expose the cubechat service'),
        isA<StateError>(),
      );
    });
  });
}
