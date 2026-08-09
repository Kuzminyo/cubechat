import 'package:cubechat/core/transport/shared_location.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/map/data/shared_map_locations_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 8, 9, 12);

  Message message({
    required String id,
    required String chatId,
    required SharedLocation location,
    bool isMine = false,
    MessageKind kind = MessageKind.text,
    DateTime? sentAt,
  }) {
    return Message(
      id: id,
      chatId: chatId,
      text: location.encode(),
      sentAt: sentAt ?? now,
      isMine: isMine,
      kind: kind,
    );
  }

  test('uses the latest incoming location for a direct chat', () {
    const oldLocation = SharedLocation(latitude: 50, longitude: 30);
    const latestLocation = SharedLocation(latitude: 51, longitude: 31);
    final history = <String, List<Message>>{
      'alice': [
        message(
          id: 'old',
          chatId: 'alice',
          location: oldLocation,
          sentAt: now.subtract(const Duration(minutes: 10)),
        ),
        message(
          id: 'latest',
          chatId: 'alice',
          location: latestLocation,
        ),
      ],
    };

    final pins = sharedMapLocationsFromHistory(history, now: now);

    expect(pins.keys, ['alice']);
    expect(pins['alice']!.location.latitude, 51);
    expect(pins['alice']!.location.longitude, 31);
  });

  test('an expired latest share does not revive an older location', () {
    final history = <String, List<Message>>{
      'alice': [
        message(
          id: 'old',
          chatId: 'alice',
          location: const SharedLocation(latitude: 50, longitude: 30),
        ),
        message(
          id: 'expired',
          chatId: 'alice',
          location: SharedLocation(
            latitude: 51,
            longitude: 31,
            expiresAt: now.subtract(const Duration(seconds: 1)),
          ),
        ),
      ],
    };

    final pins = sharedMapLocationsFromHistory(history, now: now);

    expect(pins, isEmpty);
  });

  test('ignores locations sent by the local user', () {
    final history = <String, List<Message>>{
      'alice': [
        message(
          id: 'mine',
          chatId: 'alice',
          location: const SharedLocation(latitude: 50, longitude: 30),
          isMine: true,
        ),
      ],
    };

    final pins = sharedMapLocationsFromHistory(history, now: now);

    expect(pins, isEmpty);
  });

  test('does not assign a channel location to one contact avatar', () {
    final history = <String, List<Message>>{
      '#crew': [
        message(
          id: 'channel',
          chatId: '#crew',
          location: const SharedLocation(latitude: 50, longitude: 30),
        ),
      ],
    };

    final pins = sharedMapLocationsFromHistory(history, now: now);

    expect(pins, isEmpty);
  });
}
