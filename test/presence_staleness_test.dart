import 'package:cubechat/features/peers/data/presence_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A relay keeps events for whoever subscribes next, so the last beacon a
/// phone managed before its battery died is handed over on the following
/// launch. Stamped with the *receiver's* clock it reads as news, and the header
/// says somebody is in the app whose phone has been off for hours — reported
/// exactly that way: switched off while inside the app, still shown as online.
void main() {
  test('a beacon is believed for its own age, not for when it arrived', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final presence = container.read(presenceControllerProvider.notifier);

    final longAgo = DateTime.now().subtract(const Duration(hours: 3));
    presence.record('ab' * 32, online: true, at: longAgo);

    expect(
      peerIsOnline(
        hasLiveSession: false,
        beacon: container.read(presenceControllerProvider)['ab' * 32],
        lastSeen: DateTime.now(),
      ),
      isFalse,
      reason: 'three hours is well past the beacon TTL',
    );
  });

  test('a fresh one still counts', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(presenceControllerProvider.notifier).record(
          'ab' * 32,
          online: true,
          at: DateTime.now().subtract(const Duration(seconds: 5)),
        );

    expect(
      peerIsOnline(
        hasLiveSession: false,
        beacon: container.read(presenceControllerProvider)['ab' * 32],
        lastSeen: null,
      ),
      isTrue,
    );
  });

  test('an older beacon never displaces a newer one', () {
    // Two relays hand over the same backlog in whatever order they connect.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final presence = container.read(presenceControllerProvider.notifier);
    final now = DateTime.now();

    presence.record('ab' * 32, online: false, at: now);
    presence.record(
      'ab' * 32,
      online: true,
      at: now.subtract(const Duration(minutes: 10)),
    );

    expect(
      container.read(presenceControllerProvider)['ab' * 32]?.online,
      isFalse,
      reason: 'they said goodbye after they said hello',
    );
  });
}
