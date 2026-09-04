import 'package:cubechat/core/transport/messaging_service.dart';
import 'package:cubechat/features/peers/data/presence_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  PresenceController presence() =>
      container.read(presenceControllerProvider.notifier);

  const anna = 'a';

  test('a beacon older than the window is not fresh', () {
    presence().record(
      anna,
      online: true,
      hidesLastSeen: false,
      at: DateTime.now().subtract(const Duration(minutes: 5)),
    );

    // The state still holds it — the sweep runs on a timer — but nobody
    // reading it is told the peer is here.
    expect(presence().freshFor(anna), isNull);
    expect(container.read(presenceControllerProvider)[anna]?.isFresh, isFalse);
  });

  test('a recent beacon is fresh', () {
    presence().record(anna, online: true, hidesLastSeen: false);
    expect(presence().freshFor(anna)?.online, isTrue);
  });

  test('the window outlives one late beacon and not much else', () {
    // Pinned against the heartbeat rather than against a number, because the
    // rule is a relationship: the window has to survive a beacon that arrives
    // late — a relay reconnect, the fan-out pacing — or a peer sitting still
    // would blink. It used to survive a beacon lost *outright* (two whole
    // heartbeats), and that margin was paid for by everybody watching a dot
    // stay lit for two and a half minutes after somebody lost their network,
    // which is what it was reported as. One cadence plus real slack, no more.
    final beat = MessagingService.presenceHeartbeat.inSeconds;
    expect(PeerPresence.ttl.inSeconds, greaterThan(beat + 20));
    expect(PeerPresence.ttl.inSeconds, lessThan(beat * 2));
  });

  test('an older beacon never overwrites a newer one', () {
    final now = DateTime.now();
    presence().record(anna, online: true, hidesLastSeen: false, at: now);
    presence().record(
      anna,
      online: false,
      hidesLastSeen: false,
      at: now.subtract(const Duration(seconds: 30)),
    );

    // A stale goodbye arriving behind a fresh hello must not flip the dot.
    expect(presence().freshFor(anna)?.online, isTrue);
  });

  test('clearing leaves nothing behind', () {
    presence().record(anna, online: true, hidesLastSeen: false);
    presence().clear();
    expect(container.read(presenceControllerProvider), isEmpty);
  });
}
