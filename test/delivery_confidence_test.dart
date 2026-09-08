import 'dart:io';

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
      // Source-checked: reaching this needs a relay pool, a signer and a live
      // socket, and what matters is the branch, not the plumbing.
      final source =
          File('lib/core/transport/messaging_service.dart').readAsStringSync();
      expect(
        source,
        contains('if (!receipt.isAccepted) {'),
        reason: 'without this, total silence returns true and the message is '
            'never handed to store-and-forward',
      );
      final at = source.indexOf('if (!receipt.isAccepted) {');
      expect(
        source.substring(at, at + 260),
        contains('return false'),
        reason: 'false is what routes it into the outbox to be retried',
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

  group('the map parks the radio when it cannot locate the phone', () {
    late final String source;

    setUpAll(() {
      source = File('lib/features/map/data/map_presence_controller.dart')
          .readAsStringSync();
    });

    test('a brake exists for being unable to find a fix', () {
      // `_beaconIsLanding` answers "is anybody receiving this", which is a
      // different question. A log had six 20-second GPS timeouts ninety
      // seconds apart, unbroken, each ending in the stale coordinate it would
      // have used anyway.
      expect(source, contains('bool get _canLocate'));
      expect(source, contains('if (!_canLocate) return;'));
    });

    test('and any fix at all releases it', () {
      final at = source.indexOf('void _noteStamped(');
      expect(at, isNonNegative);
      expect(
        source.substring(at, at + 700),
        contains('_lostRounds = 0;'),
        reason: 'the park is because asking again is futile, not because the '
            'phone is written off — one arriving on its own ends the reason',
      );
    });
  });
}
