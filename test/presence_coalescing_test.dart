import 'package:cubechat/features/peers/data/presence_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A relay hands over its backlog in one go, and every beacon in it is newer
/// than the last — so each passes the ordering guard and each used to be a
/// separate notification. A shared log caught thirteen presence events inside
/// one second, 18:05:50.294 through .347, all about the same person, while the
/// frame panel from that session read build 18.7 ms against raster 1.3 ms: the
/// whole cost was rebuilding, and every one of those rebuilds was on the way to
/// the same final answer.
void main() {
  final peer = 'ab' * 32;

  test('a burst of beacons is two notifications, not one per beacon', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    var notifications = 0;
    container.listen(
      presenceControllerProvider,
      (_, __) => notifications++,
      fireImmediately: false,
    );

    final now = DateTime.now();
    final presence = container.read(presenceControllerProvider.notifier);
    // Ascending timestamps, which is how a backlog arrives and why the
    // ordering guard lets every one of them through.
    for (var i = 0; i < 13; i++) {
      presence.record(
        peer,
        online: i.isEven,
        at: now.subtract(Duration(milliseconds: 13 - i)),
      );
    }

    // Leading edge only, so far.
    expect(notifications, 1);

    await Future<void>.delayed(const Duration(milliseconds: 200));

    // One more for everything that queued behind it.
    expect(notifications, 2);
  });

  test('the value that survives a burst is the newest one', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final presence = container.read(presenceControllerProvider.notifier);
    final now = DateTime.now();

    presence.record(peer, online: true, at: now.subtract(const Duration(seconds: 3)));
    presence.record(peer, online: false, at: now.subtract(const Duration(seconds: 2)));
    presence.record(peer, online: true, at: now.subtract(const Duration(seconds: 1)));

    // Exact immediately: only the notification waits, never the answer.
    expect(presence.freshFor(peer)?.online, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(presence.freshFor(peer)?.online, isTrue);
    expect(container.read(presenceControllerProvider)[peer]?.online, isTrue);
  });

  test('a single beacon is not delayed', () async {
    // The ordinary case — somebody opens the app — has nothing to collapse
    // with, and must not pay a tenth of a second for the case that does.
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(presenceControllerProvider.notifier).record(peer, online: true);

    expect(container.read(presenceControllerProvider)[peer]?.online, isTrue);
  });

  test('an emergency wipe is not undone by a buffered beacon', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final presence = container.read(presenceControllerProvider.notifier);
    final now = DateTime.now();

    presence.record(peer, online: true, at: now.subtract(const Duration(seconds: 2)));
    presence.record(peer, online: true, at: now.subtract(const Duration(seconds: 1)));
    presence.clear();

    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(container.read(presenceControllerProvider), isEmpty);
    expect(presence.freshFor(peer), isNull);
  });
}
