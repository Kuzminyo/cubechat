import 'dart:typed_data';

import 'package:cubechat/features/call/domain/call_record.dart';
import 'package:cubechat/features/call/domain/call_state_machine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final callId = Uint8List(16);

  CallOutcome outcome({
    required bool outgoing,
    required CallEndCause cause,
    Duration talkedFor = Duration.zero,
  }) =>
      CallOutcome(
        callId: callId,
        outgoing: outgoing,
        cause: cause,
        talkedFor: talkedFor,
      );

  test('an answered call round-trips its direction and its length', () {
    final text = encodeCallRecord(outcome(
      outgoing: true,
      cause: CallEndCause.hungUp,
      talkedFor: const Duration(minutes: 2, seconds: 31),
    ));
    final back = tryParseCallRecord(text)!;
    expect(back.outgoing, isTrue);
    expect(back.answered, isTrue);
    expect(back.talkedFor, const Duration(minutes: 2, seconds: 31));
  });

  test('everything that never connected is an unanswered call', () {
    for (final cause in [
      CallEndCause.noAnswer,
      CallEndCause.declined,
      CallEndCause.busy,
      CallEndCause.unavailable,
      CallEndCause.failed,
    ]) {
      final back = tryParseCallRecord(
        encodeCallRecord(outcome(outgoing: false, cause: cause)),
      )!;
      expect(back.answered, isFalse, reason: '$cause is not an answered call');
      expect(back.talkedFor, Duration.zero);
    }
  });

  test('a hangup with no talk time at all is not an answered call', () {
    // The boundary itself: `talkedFor > Duration.zero` is what decides
    // `answered`, so a hangup at exactly zero must land on the unanswered
    // side. Flipping that `>` to `>=` would turn every unanswered hungUp
    // call into an answered one, and nothing else here would catch it.
    final text = encodeCallRecord(outcome(
      outgoing: true,
      cause: CallEndCause.hungUp,
      talkedFor: Duration.zero,
    ));
    final back = tryParseCallRecord(text)!;
    expect(back.answered, isFalse);
    expect(back.talkedFor, Duration.zero);
  });

  test('a call lost to a simultaneous dial leaves no record at all', () {
    // Both people are about to be in the very call that replaced it. Two lines
    // for one conversation is the confusing outcome, not the tidy one.
    expect(
      encodeCallRecord(outcome(outgoing: true, cause: CallEndCause.glareLost)),
      isEmpty,
    );
  });

  test('ordinary text is not mistaken for a record', () {
    expect(tryParseCallRecord('позвони мне'), isNull);
    expect(tryParseCallRecord('cubechat:loc:v1:abc'), isNull);
    expect(tryParseCallRecord(''), isNull);
  });

  test('a corrupt record is refused rather than half-read', () {
    expect(tryParseCallRecord('${callMarker}not-base64!!'), isNull);
    expect(tryParseCallRecord(callMarker), isNull);
  });
}
