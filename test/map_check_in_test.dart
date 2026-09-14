import 'package:cubechat/core/transport/shared_location.dart';
import 'package:cubechat/core/util/location_service.dart';
import 'package:cubechat/features/map/data/map_friends_controller.dart';
import 'package:cubechat/features/map/data/map_presence_controller.dart';
import 'package:cubechat/features/peers/data/known_peers_controller.dart';
import 'package:cubechat/features/peers/models/known_peer.dart';
import 'package:cubechat/features/profile/data/privacy_settings_controller.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A location on the map is a check-in a person makes, each time, by hand.
///
/// App Store review rejected the build under guideline 5.1.2(i): the app
/// displayed users' locations on a map without the precautions Apple requires.
/// Two of those precautions are what this file pins. A position is shown only
/// after the person asks for it to be — "require users to manually check in
/// each time … there should be no option to enable automatic check ins" — and a
/// blocked user is not shown it.
///
/// Before this, sharing was a switch: once on, a 45-second timer and a
/// background position subscription kept a friend's map current with no
/// further action at all, which is exactly the automatic check-in the review
/// named.
class _Privacy extends PrivacySettingsController {
  _Privacy(this.sharing);
  final bool sharing;
  @override
  PrivacySettings build() =>
      PrivacySettings.initial.copyWith(shareMapLocation: sharing);
  @override
  Future<void> setShareMapLocation(bool value) async {
    state = state.copyWith(shareMapLocation: value);
  }
}

class _Friends extends MapFriendsController {
  _Friends(this.friends);
  final Set<String> friends;
  @override
  Set<String> build() => friends;
}

class _Peers extends KnownPeersController {
  _Peers(this.peers);
  Map<String, KnownPeer> peers;
  @override
  Map<String, KnownPeer> build() => peers;
  void replace(Map<String, KnownPeer> next) => state = next;
}

KnownPeer _peer(String id, {bool blocked = false}) => KnownPeer(
      pubkeyHex: id,
      displayName: id,
      lastSeen: DateTime(2026),
      blockedAt: blocked ? DateTime(2026) : null,
    );

const _here = LocationFix(latitude: 50.45, longitude: 30.52, accuracyMetres: 8);

void main() {
  late List<(String, SharedLocation)> sent;
  late int fixes;

  ProviderContainer build({
    bool sharing = true,
    Set<String> friends = const {'alice', 'bob'},
    Map<String, KnownPeer>? peers,
    LocationFix? fix = _here,
  }) {
    sent = [];
    fixes = 0;
    return ProviderContainer(overrides: [
      privacySettingsProvider.overrideWith(() => _Privacy(sharing)),
      mapFriendsControllerProvider.overrideWith(() => _Friends(friends)),
      knownPeersControllerProvider.overrideWith(() => _Peers(
            peers ?? {for (final id in friends) id: _peer(id)},
          )),
      mapLocationReaderProvider.overrideWithValue(() async {
        fixes++;
        return (fix, fix == null ? LocationFailure.unavailable : null);
      }),
      mapBeaconSenderProvider.overrideWithValue((peerId, text) async {
        sent.add((peerId, SharedLocation.tryParse(text)!));
        return true;
      }),
    ]);
  }

  test('nothing is published, and nothing located, without a check-in', () {
    fakeAsync((async) {
      final container = build();
      container.read(mapPresenceControllerProvider);
      async.elapse(const Duration(hours: 3));
      async.flushMicrotasks();
      expect(sent, isEmpty,
          reason: 'no timer, no subscription: the map is never current on its '
              'own');
      expect(fixes, 0,
          reason: 'the phone is not even asked where it is');
      container.dispose();
    });
  });

  test('a check-in sends one position to each friend, visible for an hour',
      () async {
    final container = build();
    final before = DateTime.now();
    final result =
        await container.read(mapPresenceControllerProvider.notifier).checkIn();
    expect(result, CheckInResult.done);
    expect(fixes, 1);
    expect(sent.map((s) => s.$1), unorderedEquals(['alice', 'bob']));
    for (final (_, location) in sent) {
      expect(location.presence, isTrue);
      expect(location.retraction, isFalse);
      final lasts = location.expiresAt!.difference(before);
      expect(lasts, greaterThanOrEqualTo(MapPresenceController.checkInLasts));
      expect(lasts,
          lessThan(MapPresenceController.checkInLasts + const Duration(minutes: 1)));
    }
    expect(container.read(mapPresenceControllerProvider), isNotNull,
        reason: 'the screen shows until when');
    container.dispose();
  });

  test('a check-in does not repeat itself', () {
    fakeAsync((async) {
      final container = build();
      container.read(mapPresenceControllerProvider.notifier).checkIn();
      async.flushMicrotasks();
      final once = sent.length;
      async.elapse(const Duration(hours: 2));
      async.flushMicrotasks();
      expect(sent.length, once,
          reason: 'there should be no option to enable automatic check ins');
      container.dispose();
    });
  });

  test('without consent there is no check-in at all', () async {
    final container = build(sharing: false);
    final result =
        await container.read(mapPresenceControllerProvider.notifier).checkIn();
    expect(result, CheckInResult.noConsent);
    expect(sent, isEmpty);
    expect(fixes, 0, reason: 'no location is asked for before consent');
    container.dispose();
  });

  test('a blocked user is never sent a check-in', () async {
    final container = build(peers: {
      'alice': _peer('alice'),
      'bob': _peer('bob', blocked: true),
    });
    await container.read(mapPresenceControllerProvider.notifier).checkIn();
    expect(sent.map((s) => s.$1), ['alice']);
    container.dispose();
  });

  test('with every friend blocked there is nobody to show, and no fix is taken',
      () async {
    final container = build(peers: {
      'alice': _peer('alice', blocked: true),
      'bob': _peer('bob', blocked: true),
    });
    final result =
        await container.read(mapPresenceControllerProvider.notifier).checkIn();
    expect(result, CheckInResult.nobodyToShow);
    expect(fixes, 0);
    expect(sent, isEmpty);
    container.dispose();
  });

  test('blocking a friend after a check-in takes the pin back from them',
      () async {
    final container = build();
    await container.read(mapPresenceControllerProvider.notifier).checkIn();
    sent.clear();
    (container.read(knownPeersControllerProvider.notifier) as _Peers).replace({
      'alice': _peer('alice'),
      'bob': _peer('bob', blocked: true),
    });
    await Future<void>.delayed(Duration.zero);
    expect(sent.map((s) => s.$1), ['bob']);
    expect(sent.single.$2.retraction, isTrue);
    container.dispose();
  });

  test('stopping takes the pin back from everyone and clears the time',
      () async {
    final container = build();
    final notifier = container.read(mapPresenceControllerProvider.notifier);
    await notifier.checkIn();
    sent.clear();
    await notifier.withdraw();
    expect(sent.map((s) => s.$1), unorderedEquals(['alice', 'bob']));
    expect(sent.every((s) => s.$2.retraction), isTrue);
    expect(container.read(mapPresenceControllerProvider), isNull);
    container.dispose();
  });

  test('turning consent off takes the pin back', () async {
    final container = build();
    await container.read(mapPresenceControllerProvider.notifier).checkIn();
    sent.clear();
    await container
        .read(privacySettingsProvider.notifier)
        .setShareMapLocation(false);
    await Future<void>.delayed(Duration.zero);
    expect(sent, hasLength(2));
    expect(sent.every((s) => s.$2.retraction), isTrue);
    container.dispose();
  });

  test('a phone that cannot find itself says so and sends nothing', () async {
    final container = build(fix: null);
    final result =
        await container.read(mapPresenceControllerProvider.notifier).checkIn();
    expect(result, CheckInResult.noFix);
    expect(sent, isEmpty);
    container.dispose();
  });
}
