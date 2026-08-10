import 'dart:io';

import 'package:cubechat/core/transport/shared_location.dart';
import 'package:cubechat/features/chat/data/message_visibility.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/map/data/shared_map_locations_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'support/hive_settle.dart';

/// The map's presence beacon is a position emitted every 45 seconds, to every
/// map friend, for as long as the screen is open. It travels as a text message
/// because that is what already gets encrypted, signed and routed — but it is
/// not one, and the difference is what these tests hold in place: a beacon
/// never becomes a bubble, never lands in history, and never counts as unread.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sentAt = DateTime(2026, 8, 10, 12);

  Message textMessage(String text, {DateTime? at, bool isMine = false}) =>
      Message(
        id: 'm1',
        chatId: 'peer',
        text: text,
        sentAt: at ?? sentAt,
        isMine: isMine,
      );

  group('the beacon flag', () {
    test('survives the round trip', () {
      final beacon = SharedLocation(
        latitude: 50.4501,
        longitude: 30.5234,
        expiresAt: sentAt.add(const Duration(minutes: 2)),
        presence: true,
      );
      final back = SharedLocation.tryParse(beacon.encode());
      expect(back, isNotNull);
      expect(back!.presence, isTrue);
      expect(back.latitude, closeTo(50.4501, 0.000001));
    });

    test('a hand-shared position is not a beacon', () {
      const shared = SharedLocation(latitude: 50.45, longitude: 30.52);
      expect(SharedLocation.tryParse(shared.encode())!.presence, isFalse);
    });

    // An older build encodes four fields and knows nothing about the fifth.
    // Its beacons still have to be recognised, or every one of them stays a
    // bubble in the chat after this build ships.
    test('an untagged two-minute window is still read as a beacon', () {
      final legacy = SharedLocation(
        latitude: 50.45,
        longitude: 30.52,
        expiresAt: sentAt.add(const Duration(minutes: 2)),
      ).encode();
      expect(SharedLocation.isBeaconText(legacy, sentAt), isTrue);
    });

    test('the fifteen-minute share option is not mistaken for a beacon', () {
      final shared = SharedLocation(
        latitude: 50.45,
        longitude: 30.52,
        expiresAt: sentAt.add(const Duration(minutes: 15)),
      ).encode();
      expect(SharedLocation.isBeaconText(shared, sentAt), isFalse);
    });

    test('a share with no expiry is not a beacon', () {
      const shared = SharedLocation(latitude: 50.45, longitude: 30.52);
      expect(SharedLocation.isBeaconText(shared.encode(), sentAt), isFalse);
    });

    test('ordinary text is not a beacon', () {
      expect(SharedLocation.isBeaconText('see you at eight', sentAt), isFalse);
    });

    // The relay hands over its backlog on every reconnect, so the heartbeats
    // that piled up while the app slept all arrive at once, hours past their
    // window. Read by the clock they look nothing like a beacon — which is how
    // a burst of base64 URIs used to appear in the conversation on every wake.
    test('a beacon replayed long after its window is still a beacon', () {
      final stale = SharedLocation(
        latitude: 50.45,
        longitude: 30.52,
        expiresAt: sentAt.subtract(const Duration(hours: 6)),
      ).encode();
      expect(SharedLocation.isBeaconText(stale, sentAt), isTrue);
    });

    test('a withdrawal survives the round trip and reads as a beacon', () {
      final gone = SharedLocation(
        latitude: 0,
        longitude: 0,
        expiresAt: sentAt.subtract(const Duration(seconds: 1)),
        presence: true,
        retract: true,
      );
      final back = SharedLocation.tryParse(gone.encode());
      expect(back, isNotNull);
      expect(back!.retract, isTrue);
      expect(back.presence, isTrue);
      expect(SharedLocation.isBeaconText(gone.encode(), sentAt), isTrue);
    });

    // A build that predates the flag encodes its withdrawal as an expired
    // beacon at exactly (0, 0), and those still have to take the pin down.
    test('the legacy (0, 0) sentinel still reads as a withdrawal', () {
      final gone = SharedLocation(
        latitude: 0,
        longitude: 0,
        expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
        presence: true,
      );
      expect(gone.retraction, isTrue);
    });

    test('an expired position somewhere real is not a withdrawal', () {
      final stale = SharedLocation(
        latitude: 50.45,
        longitude: 30.52,
        expiresAt: DateTime.now().subtract(const Duration(hours: 2)),
        presence: true,
      );
      expect(stale.retraction, isFalse);
    });
  });

  group('what the conversation shows', () {
    test('beacons are hidden and real messages are kept', () {
      final beacon = SharedLocation(
        latitude: 50.45,
        longitude: 30.52,
        expiresAt: sentAt.add(const Duration(minutes: 2)),
        presence: true,
      ).encode();
      final messages = [
        textMessage('on my way'),
        textMessage(beacon),
        textMessage('here'),
      ];
      final visible = visibleMessages(messages);
      expect(visible.map((m) => m.text), ['on my way', 'here']);
      expect(lastVisibleMessage(messages)?.text, 'here');
    });

    test('a chat of nothing but beacons previews as nothing', () {
      final beacon = SharedLocation(
        latitude: 50.45,
        longitude: 30.52,
        expiresAt: sentAt.add(const Duration(minutes: 2)),
        presence: true,
      ).encode();
      expect(lastVisibleMessage([textMessage(beacon)]), isNull);
    });

    test('a list with no beacons is returned untouched', () {
      final messages = [textMessage('hello')];
      expect(identical(visibleMessages(messages), messages), isTrue);
    });
  });

  // The store keeps its pins on disk, so it needs somewhere to put them: with
  // no Hive directory the box open fails from a constructor nobody awaits, and
  // the error lands on whichever test happens to be running.
  group('the presence store', () {
    late Directory tempDir;
    late ProviderContainer container;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cubechat_map_test_');
      Hive.init(tempDir.path);
      container = ProviderContainer();
    });

    tearDown(() async {
      await settleBackgroundStorage();
      container.dispose();
      await Hive.close();
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows may hold a Hive file briefly after close.
      }
    });

    test('records a live position', () {
      container.read(mapPresenceStoreProvider.notifier).record(
            'peer',
            SharedLocation(
              latitude: 50.45,
              longitude: 30.52,
              expiresAt: DateTime.now().add(const Duration(minutes: 2)),
              presence: true,
            ),
          );
      final stored = container.read(mapPresenceStoreProvider)['peer'];
      expect(stored, isNotNull);
      expect(stored!.location.latitude, closeTo(50.45, 0.000001));
    });

    // Switching map sharing off sends an already-expired beacon. Treating it as
    // a removal is what makes the pin vanish at once, instead of standing there
    // for the two minutes its predecessor was good for.
    test('an expired beacon retracts the pin', () {
      final store = container.read(mapPresenceStoreProvider.notifier);
      store.record(
        'peer',
        SharedLocation(
          latitude: 50.45,
          longitude: 30.52,
          expiresAt: DateTime.now().add(const Duration(minutes: 2)),
          presence: true,
        ),
      );
      expect(container.read(mapPresenceStoreProvider), contains('peer'));

      store.record(
        'peer',
        SharedLocation(
          latitude: 0,
          longitude: 0,
          expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
          presence: true,
        ),
      );
      expect(container.read(mapPresenceStoreProvider), isNot(contains('peer')));
    });

    // The one that used to empty the map: a friend closes the app, the relay
    // later hands over the heartbeats it was holding, and every one of them is
    // expired on arrival. They are not withdrawals — they are the last place
    // that person was seen, which is precisely what the map is for.
    test('a replayed beacon leaves the standing pin alone', () {
      final store = container.read(mapPresenceStoreProvider.notifier);
      store.record(
        'peer',
        SharedLocation(
          latitude: 50.45,
          longitude: 30.52,
          expiresAt: DateTime.now().add(const Duration(minutes: 2)),
          presence: true,
        ),
      );
      store.record(
        'peer',
        SharedLocation(
          latitude: 49.0,
          longitude: 31.0,
          expiresAt: DateTime.now().subtract(const Duration(hours: 3)),
          presence: true,
        ),
      );
      final stored = container.read(mapPresenceStoreProvider)['peer'];
      expect(stored, isNotNull);
      expect(stored!.location.latitude, closeTo(50.45, 0.000001));
    });

    // Nothing else knows where they are, so a stale position is still better
    // than an empty map — dated by the window it carried, not by the moment the
    // relay got round to handing it over.
    test('a replayed beacon for an unseen friend stands as last known', () {
      final expiry = DateTime.now().subtract(const Duration(hours: 3));
      container.read(mapPresenceStoreProvider.notifier).record(
            'peer',
            SharedLocation(
              latitude: 49.0,
              longitude: 31.0,
              expiresAt: expiry,
              presence: true,
            ),
          );
      final stored = container.read(mapPresenceStoreProvider)['peer'];
      expect(stored, isNotNull);
      expect(stored!.sentAt, expiry);
    });

    test('a flagged withdrawal retracts the pin', () {
      final store = container.read(mapPresenceStoreProvider.notifier);
      store.record(
        'peer',
        SharedLocation(
          latitude: 50.45,
          longitude: 30.52,
          expiresAt: DateTime.now().add(const Duration(minutes: 2)),
          presence: true,
        ),
      );
      store.record(
        'peer',
        SharedLocation(
          latitude: 0,
          longitude: 0,
          expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
          presence: true,
          retract: true,
        ),
      );
      expect(container.read(mapPresenceStoreProvider), isNot(contains('peer')));
    });

    test('a withdrawal out of the backlog no longer takes the pin down', () {
      final store = container.read(mapPresenceStoreProvider.notifier);
      store.record(
        'peer',
        SharedLocation(
          latitude: 50.45,
          longitude: 30.52,
          expiresAt: DateTime.now().add(const Duration(minutes: 2)),
          presence: true,
        ),
      );
      store.record(
        'peer',
        SharedLocation(
          latitude: 0,
          longitude: 0,
          expiresAt: DateTime.now().subtract(const Duration(hours: 8)),
          presence: true,
          retract: true,
        ),
      );
      expect(container.read(mapPresenceStoreProvider), contains('peer'));
    });

    test('removing a friend drops their pin', () {
      final store = container.read(mapPresenceStoreProvider.notifier);
      store.record(
        'peer',
        SharedLocation(
          latitude: 50.45,
          longitude: 30.52,
          expiresAt: DateTime.now().add(const Duration(minutes: 2)),
          presence: true,
        ),
      );
      store.forget('peer');
      expect(container.read(mapPresenceStoreProvider), isEmpty);
    });

    // Channels mix several authors into one bucket, so a pin there could not be
    // attributed to anybody.
    test('a channel never gets a pin', () {
      container.read(mapPresenceStoreProvider.notifier).record(
            '#room',
            SharedLocation(
              latitude: 50.45,
              longitude: 30.52,
              expiresAt: DateTime.now().add(const Duration(minutes: 2)),
              presence: true,
            ),
          );
      expect(container.read(mapPresenceStoreProvider), isEmpty);
    });
  });
}
