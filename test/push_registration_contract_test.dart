import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/notifications/push_registration_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The wake service and this app agree on two byte layouts, and neither
/// disagreement would fail loudly:
///
///  * the **registration transcript** — a mismatch makes every signature look
///    forged, and the server answers 401 with no clue why;
///  * the **capability lookup** — a mismatch means a wake never matches a row,
///    and the endpoint answers 202 either way *by design*, so the failure is
///    completely silent.
///
/// So the expected values here were produced by the Node implementation
/// (`server/wake/src/crypto.js`) and pasted in. If either side's layout is
/// edited, this test fails on the spot rather than in the field.
void main() {
  Uint8List filled(int len, int byte) =>
      Uint8List.fromList(List<int>.filled(len, byte));

  group('wake-service wire contract', () {
    test('the registration transcript matches the server byte for byte',
        () async {
      final transcript = PushRegistrationService.registrationTranscript(
        controlPubkey: filled(32, 7),
        deviceToken: filled(4, 9),
        environment: 'sandbox',
        topic: 'com.cubechat.cubechat',
        timestamp: 1700000000,
        nonce: filled(16, 3),
      );

      expect(transcript.length, 137, reason: 'layout drifted');

      final digest = await Sha256().hash(transcript);
      final hex =
          digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(
        hex,
        '68a1b6bd2cb7714a248ce31ceb803745bed79f4d1f9f4cc70d02aad57d6fd090',
        reason: 'computed by server/wake/src/crypto.js registrationTranscript',
      );
    });

    test('the capability lookup matches the server', () async {
      final lookup = await PushRegistrationService.capabilityLookup(
        PushRegistrationService.capDomain,
        filled(32, 5),
      );
      expect(
        lookup,
        'b_FhBVX0S3j7o_gSkwlVSai8sfKNHTBGQblfhJ2NpT8',
        reason: 'computed by server/wake/src/crypto.js lookupOf',
      );
    });

    test('the domain separator carries its NUL', () {
      // A literal NUL in the source made the file read as binary; it is
      // escaped now, and this is what catches it being dropped in an edit.
      final short = PushRegistrationService.registrationTranscript(
        controlPubkey: filled(32, 0),
        deviceToken: filled(1, 0),
        environment: 'sandbox',
        topic: 'a',
        timestamp: 0,
        nonce: filled(16, 0),
      );
      // "cubechat/apns-ticket-register/v1" is 32 characters, so the NUL that
      // terminates it is byte 32 and the domain occupies 33.
      expect(short[32], 0, reason: 'the domain must end in a NUL byte');
      expect(short.length, 33 + 32 + 8 + 1 + 7 + 8 + 1 + 8 + 16);
    });
  });
}
