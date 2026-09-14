import 'dart:io';

import 'package:cubechat/core/transport/control_delivery.dart';
import 'package:cubechat/core/transport/nostr/nostr_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// What counts as having sent something, and what a receipt actually did.
///
/// Both were single numbers standing for two different facts, and in both
/// cases the ambiguity cost an investigation.
void main() {
  group('a publish nobody confirmed is not a delivery', () {
    // The rule used to be "silence is acceptance", on the grounds that falling
    // back to store-and-forward for one slow relay would strand messages
    // behind it. That is right about *one* relay and wrong about all of them:
    // a shipped log had 16 publishes in 150 accepted by nobody, beside
    // `relay.primal.net down (Connection closed before full header)` — which
    // is the "смс не доходят" report arriving as a message the chat showed as
    // sent.

    test('one straggler beside an acceptance is still delivered', () {
      const receipt = PublishReceipt(sentTo: 3, accepted: 1, rejected: 0);
      expect(receipt.isAccepted, isTrue,
          reason: 'the publish settles on the first OK and does not wait for '
              'the rest, so this is the ordinary successful shape');
      expect(receipt.isRefused, isFalse);
    });

    test('everybody silent is neither accepted nor refused', () {
      const receipt = PublishReceipt(sentTo: 3, accepted: 0, rejected: 0);
      expect(receipt.isAccepted, isFalse,
          reason: 'nobody said yes inside the deadline, so nothing may be '
              'reported as sent');
      expect(receipt.isRefused, isFalse,
          reason: 'and nobody said no either — this is silence, not refusal, '
              'and the two get different log lines');
    });

    test('the send path holds a frame nobody confirmed', () {
      // Silence is read as unconfirmed — not accepted — and the bool every
      // holding sender reads is true for accepted alone. Since 2026-09-14 the
      // three-way answer is kept for calls, which must not treat silence as
      // failure either (see control_delivery_test.dart); the outbox still sees
      // exactly the false it always did.
      expect(
        RelayPublishOutcome.fromReceipt(
          const PublishReceipt(sentTo: 3, accepted: 0, rejected: 0),
        ),
        RelayPublishOutcome.unconfirmed,
      );
      // Source-checked: reaching this needs a relay pool, a signer and a live
      // socket, and what matters is the branch, not the plumbing.
      final source =
          File('lib/core/transport/messaging_service.dart').readAsStringSync();
      final at = source.indexOf('Future<bool> _sendOverNostr(');
      expect(at, isNonNegative);
      expect(
        source.substring(at, at + 400),
        matches(RegExp(r'==\s*RelayPublishOutcome\.accepted;')),
        reason: 'without this, total silence returns true and the message is '
            'never handed to store-and-forward',
      );
    });
  });

  group('a receipt says which of three things happened', () {
    // "2 id(s), 1 marked" was read as a handle having gone missing. The far
    // likelier reading is the same receipt arriving again from a second relay
    // and finding the message already read — which is the mechanism working.
    late final String source;

    setUpAll(() {
      source = File('lib/features/chat/data/messages_controller.dart')
          .readAsStringSync();
    });

    test('already-read is counted apart from unknown', () {
      expect(source, contains('class MarkReadOutcome'));
      expect(source, contains('required this.alreadyRead'));
      expect(source, contains('required this.unknown'));
    });

    test('a second lookup cannot invent a second unknown', () {
      // The same ids are looked up under the canonical key and the transport
      // key. An id absent from both is one unknown, not two.
      final at = source.indexOf('MarkReadOutcome operator +');
      expect(at, isNonNegative);
      expect(
        source.substring(at, at + 400),
        contains('unknown < other.unknown ? unknown : other.unknown'),
      );
    });

    test('the log line names the one worth chasing', () {
      final service =
          File('lib/core/transport/messaging_service.dart').readAsStringSync();
      expect(service, contains('UNKNOWN'));
      expect(service, contains('already read'));
    });
  });

  // "The map parks the radio when it cannot locate the phone" lived here: a
  // brake on the live map's 45-second locate loop, after a log of six GPS
  // timeouts in a row. The loop is gone — App Store review rejected automatic
  // check-ins under guideline 5.1.2(i) — and a check-in now reads one position
  // when a person taps. There is no loop left to brake; map_check_in_test.dart
  // pins that none comes back.
}
