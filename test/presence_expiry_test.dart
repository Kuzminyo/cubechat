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

  test('the window outlives one lost beacon, and not a dead phone', () {
    // Pinned against the heartbeat rather than against a number, because the
    // rule is a relationship — and the relationship changed on 2026-09-08.
    //
    // Two reports pull opposite ways here. A window shorter than two beacons
    // means one lost beacon dims somebody who is sitting right there ("пишет
    // не в сети а только что в сети"). A window much longer than that means a
    // phone that loses its network, and so sends no goodbye, stays lit for
    // the whole of it — which is why the window was cut from 150 s to 100 on
    // 2026-09-04.
    //
    // Both are answered by moving the *cadence*, which was refused as "radio
    // is heat" until it was measured: an online beacon goes out only while the
    // app is on screen, and a 99-minute log holds four rounds. So the window
    // now fits two beacons and still expires well inside three.
    final beat = MessagingService.presenceHeartbeat.inSeconds;
    expect(PeerPresence.ttl.inSeconds, greaterThanOrEqualTo(beat * 2),
        reason: 'one lost beacon must not dim a peer who is still there');
    expect(PeerPresence.ttl.inSeconds, lessThan(beat * 3),
        reason: 'a dot that stays lit is a lie nobody can correct');
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
