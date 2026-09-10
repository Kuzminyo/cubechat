import 'package:cubechat/core/transport/call_signal.dart';
import 'package:cubechat/features/call/domain/call_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('which call frames ring a doorbell', () {
    test('only an invite takes the voip path', () {
      // iOS kills an app that takes a voip push and does not report a new
      // incoming call. A hangup has no call to report, so a voip push for one
      // would be fatal; and it does not need one, because by then the app is
      // already awake and holding a relay subscription.
      expect(callIsVoipWake(CallSignalKind.invite), isTrue);
      for (final kind in CallSignalKind.values
          .where((k) => k != CallSignalKind.invite)) {
        expect(callIsVoipWake(kind), isFalse, reason: '$kind must not');
      }
    });

    test('an invite, a hangup and a decline wake the phone; the rest do not',
        () {
      expect(callWakesPeer(CallSignalKind.invite), isTrue);
      expect(callWakesPeer(CallSignalKind.hangup), isTrue,
          reason: 'a phone that missed the hangup keeps ringing');
      expect(callWakesPeer(CallSignalKind.decline), isTrue);
      expect(callWakesPeer(CallSignalKind.ringing), isFalse);
      expect(callWakesPeer(CallSignalKind.accept), isFalse);
      expect(callWakesPeer(CallSignalKind.busy), isFalse);
    });

    test('everything that takes the voip path also wakes the phone', () {
      for (final kind in CallSignalKind.values) {
        if (callIsVoipWake(kind)) {
          expect(callWakesPeer(kind), isTrue,
              reason: '$kind asks for a voip push without asking to be woken');
        }
      }
    });
  });
}
