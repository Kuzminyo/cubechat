import 'package:cubechat/features/peers/data/presence_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  PresenceController notifier() =>
      container.read(presenceControllerProvider.notifier);

  final peer = 'ab' * 32;

  test('a beacon is remembered and reads as fresh', () {
    notifier().record(peer, online: true);
    final p = notifier().freshFor(peer);
    expect(p?.online, isTrue);
  });

  test('an offline beacon is remembered as offline, not as absence', () {
    final n = notifier();
    n.record(peer, online: true);
    n.record(peer, online: false);
    // The distinction matters in the chat header: a *known* offline beats the
    // last-seen window, while no beacon at all falls back to it.
    expect(n.freshFor(peer)?.online, isFalse);
  });

  test('a beacon past its TTL is no longer fresh', () {
    final stale = DateTime.now().subtract(PeerPresence.ttl * 2);
    notifier().record(peer, online: true, at: stale);
    expect(notifier().freshFor(peer), isNull);
    // Still in state, just not trusted — nothing to clean up on a timer.
    expect(container.read(presenceControllerProvider)[peer]?.online, isTrue);
  });

  test('a beacon that arrives out of order does not overwrite a newer one', () {
    final n = notifier();
    final now = DateTime.now();
    n.record(peer, online: true, at: now);
    n.record(peer, online: false, at: now.subtract(const Duration(minutes: 1)));
    expect(n.freshFor(peer)?.online, isTrue);
  });

  test('presence is per peer', () {
    final n = notifier();
    n.record(peer, online: true);
    n.record('cd' * 32, online: false);
    expect(n.freshFor(peer)?.online, isTrue);
    expect(n.freshFor('cd' * 32)?.online, isFalse);
  });

  test('unknown peers have no presence', () {
    expect(notifier().freshFor('ff' * 32), isNull);
  });

  test('clear forgets everyone (emergency wipe)', () {
    final n = notifier();
    n.record(peer, online: true);
    n.clear();
    expect(container.read(presenceControllerProvider), isEmpty);
  });

  group('peerIsOnline', () {
    final now = DateTime(2026, 7, 26, 16, 8);
    PeerPresence beacon(bool online, Duration ago) =>
        PeerPresence(online: online, at: now.subtract(ago));

    test('a live session is definite, whatever else says', () {
      expect(
        peerIsOnline(
          hasLiveSession: true,
          beacon: beacon(false, const Duration(seconds: 1)),
          lastSeen: null,
          now: now,
        ),
        isTrue,
      );
    });

    test('a fresh beacon puts an internet-only peer online', () {
      // The case the mesh cannot answer: no session, never in BLE range.
      expect(
        peerIsOnline(
          hasLiveSession: false,
          beacon: beacon(true, const Duration(seconds: 10)),
          lastSeen: null,
          now: now,
        ),
        isTrue,
      );
    });

    test('a fresh goodbye beats a recent last-seen', () {
      // Regression guard: an "online" beacon also refreshes lastSeen, so
      // falling through to the mesh window would keep them online for another
      // two minutes after they closed the app.
      expect(
        peerIsOnline(
          hasLiveSession: false,
          beacon: beacon(false, const Duration(seconds: 5)),
          lastSeen: now.subtract(const Duration(seconds: 20)),
          now: now,
        ),
        isFalse,
      );
    });

    test('a stale beacon falls back to the mesh window', () {
      expect(
        peerIsOnline(
          hasLiveSession: false,
          beacon: beacon(false, PeerPresence.ttl * 2),
          lastSeen: now.subtract(const Duration(seconds: 30)),
          now: now,
        ),
        isTrue,
      );
    });

    test('no beacon and a cold last-seen reads as offline', () {
      expect(
        peerIsOnline(
          hasLiveSession: false,
          beacon: null,
          lastSeen: now.subtract(const Duration(hours: 3)),
          now: now,
        ),
        isFalse,
      );
      expect(
        peerIsOnline(
          hasLiveSession: false,
          beacon: null,
          lastSeen: null,
          now: now,
        ),
        isFalse,
      );
    });
  });
}
