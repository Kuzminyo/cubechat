import 'package:cubechat/core/transport/shared_location.dart';
import 'package:cubechat/features/chat/data/message_visibility.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/map/data/shared_map_locations_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The map's presence beacon is a position emitted every 45 seconds, to every
/// map friend, for as long as the screen is open. It travels as a text message
/// because that is what already gets encrypted, signed and routed — but it is
/// not one, and the difference is what these tests hold in place: a beacon
/// never becomes a bubble, never lands in history, and never counts as unread.
void main() {
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

  group('the presence store', () {
    late ProviderContainer container;

    setUp(() => container = ProviderContainer());
    tearDown(() => container.dispose());

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
