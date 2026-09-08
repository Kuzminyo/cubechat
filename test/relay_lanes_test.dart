import 'dart:io';

import 'package:cubechat/core/transport/nostr/nostr_transport.dart';
import 'package:cubechat/features/profile/data/relay_settings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// Which relays a publish is written to, and why it is not all of them.
///
/// Public relays rate-limit **per connection** and answer a burst by throttling
/// everything in it — the code has carried that finding since damus refused a
/// fan-out with "you are noting too much". Two kinds of traffic here are bursty
/// or relentless and neither is conversation:
///
///   * media — one publish per 32 KiB chunk, so a video is a hundred events in
///     a few seconds;
///   * map beacons — a 72-minute field log had **191 of 274 publishes** be
///     these: 70% of everything the radio did, to carry 55 kB.
///
/// Both now go somewhere else, so a throttle earned by a picture or a pin does
/// not land on somebody's sentence.
void main() {
  group('the lanes are distinct and real', () {
    test('three lanes, and conversation is the default', () {
      expect(RelayLane.values, hasLength(3));
      // Anything added later has to name its lane rather than inherit one.
      expect(RelayLane.conversation.index, 0);
    });

    test('no relay serves two lanes', () {
      final conversation = RelaySettings.defaultUrls.toSet();
      final media = RelaySettings.defaultMediaUrls.toSet();
      final location = RelaySettings.defaultLocationUrls.toSet();

      expect(conversation.intersection(media), isEmpty,
          reason: 'sharing one puts the throttle straight back');
      expect(conversation.intersection(location), isEmpty);
      expect(media.intersection(location), isEmpty,
          reason: 'a relentless small signal beside a rare huge one is the '
              'same problem between two things nobody is reading');
    });

    test('each lane has more than one relay', () {
      // A lane of one is a lane that goes away when that operator does.
      expect(RelaySettings.defaultMediaUrls.length, greaterThan(1));
      expect(RelaySettings.defaultLocationUrls.length, greaterThan(1));
    });

    test('every lane relay is a wss url', () {
      for (final u in [
        ...RelaySettings.defaultMediaUrls,
        ...RelaySettings.defaultLocationUrls,
      ]) {
        expect(RelaySettingsController.isValidRelayUrl(u), isTrue, reason: u);
      }
    });
  });

  group('the split is publish-only', () {
    late final String pool;

    setUpAll(() {
      pool = File('lib/core/transport/nostr/websocket_relay_client.dart')
          .readAsStringSync();
    });

    test('lane relays join the pool, so they are subscribed to', () {
      // Nostr is publish-here-subscribe-here: a chunk written to a relay the
      // recipient does not read never arrives. This is the line that stops
      // that, and it is the one most likely to be "tidied" away.
      expect(pool, contains('...mediaRelayUrls'));
      expect(pool, contains('...locationRelayUrls'));
    });

    test('a lane with nothing up falls back to the whole pool', () {
      // A lane relay being down has to cost a slower transfer, never a lost
      // message.
      expect(pool, contains('preferred.isNotEmpty ? preferred : open'));
    });
  });

  group('what rides on which lane', () {
    late final String service;

    setUpAll(() {
      service =
          File('lib/core/transport/messaging_service.dart').readAsStringSync();
    });

    test('every media chunk and manifest takes the media lane', () {
      expect(service, contains('const lane = RelayLane.media;'));
    });

    test('the map beacon takes the location lane, and only it', () {
      // `transient` is set by exactly two callers, both in
      // MapPresenceController — the publish and the retraction — so it is also
      // the answer to which lane this is, with no second flag to keep in step.
      expect(
        service,
        contains(
            'lane: transient ? RelayLane.location : RelayLane.conversation'),
      );
    });
  });
}
