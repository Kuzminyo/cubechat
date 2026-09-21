import 'package:cubechat/core/transport/messaging_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Who a presence beacon goes to.
///
/// 2026-09-21: ~85% of what a phone sent in 21 minutes was "online" beacons,
/// every 25 s to all twelve contacts, most of whom had their app shut. The
/// heartbeat now goes to the ones who are here; everybody still hears the
/// arrival, and a full round every five minutes finds anybody lost.
void main() {
  final now = DateTime(2026, 9, 21, 21, 0);

  bool wants({
    bool online = true,
    bool fullRound = false,
    ({bool online, DateTime at})? heard,
    DateTime? told,
  }) =>
      MessagingService.presenceRoundWants(
        online: online,
        fullRound: fullRound,
        now: now,
        heard: heard,
        toldOnlineAt: told,
      );

  group('the heartbeat', () {
    test('goes to somebody whose last word was "online", recently', () {
      expect(
        wants(heard: (online: true, at: now.subtract(const Duration(minutes: 3)))),
        isTrue,
      );
    });

    test('not to somebody who said goodbye', () {
      expect(
        wants(heard: (online: false, at: now.subtract(const Duration(seconds: 30)))),
        isFalse,
      );
    });

    test('not to somebody silent for longer than the active window', () {
      expect(
        wants(heard: (online: true, at: now.subtract(const Duration(minutes: 11)))),
        isFalse,
      );
    });

    test('not to somebody never heard from', () {
      expect(wants(), isFalse);
    });

    test('a full round goes to everybody', () {
      expect(wants(fullRound: true), isTrue);
    });
  });

  group('a full round', () {
    bool full({
      bool online = true,
      bool arriving = false,
      DateTime? last,
    }) =>
        MessagingService.presenceIsFullRound(
          online: online,
          arriving: arriving,
          lastFullRound: last,
          now: now,
        );

    test('is every arrival', () {
      expect(full(arriving: true, last: now), isTrue);
    });

    test('is a heartbeat five minutes after the last one', () {
      expect(full(last: now.subtract(const Duration(minutes: 5))), isTrue);
      expect(full(last: now.subtract(const Duration(minutes: 2))), isFalse);
    });

    test('never a goodbye', () {
      expect(full(online: false), isFalse);
    });
  });

  group('the goodbye', () {
    test('goes to whoever we told we were here within the window', () {
      expect(
        wants(online: false, told: now.subtract(const Duration(seconds: 40))),
        isTrue,
      );
    });

    test('not to somebody whose beacon from us has lapsed anyway', () {
      expect(
        wants(online: false, told: now.subtract(const Duration(minutes: 3))),
        isFalse,
      );
      expect(wants(online: false), isFalse);
    });
  });
}
