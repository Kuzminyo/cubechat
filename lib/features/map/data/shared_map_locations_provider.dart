import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/transport/shared_location.dart';
import '../../chat/data/messages_controller.dart';
import '../../chat/models/message.dart';

/// A contact's latest position that they explicitly sent in the conversation.
@immutable
class SharedMapLocation {
  const SharedMapLocation({
    required this.chatId,
    required this.location,
    required this.sentAt,
  });

  final String chatId;
  final SharedLocation location;
  final DateTime sentAt;
}

/// Where map friends are *right now*, as told by the 45-second beacon.
///
/// Deliberately not chat history. A beacon is transport: it arrives every 45
/// seconds per friend for as long as their map is open, and filing that in the
/// conversation meant a bubble the user had to scroll past every 45 seconds, a
/// history that grew without anybody saying anything, and — because each one
/// counted as an unread inbound message — a read receipt owed for every single
/// one, which is what drowned the relay. So beacons live here instead: in
/// memory, keyed by peer, one entry each, gone when the app closes.
///
/// A beacon whose expiry has passed *removes* the entry rather than replacing
/// it. That is what makes withdrawal work: switching off map sharing sends a
/// beacon already expired, and every friend's pin disappears at once instead of
/// lingering until its own TTL ran out.
class MapPresenceStore extends Notifier<Map<String, SharedMapLocation>> {
  @override
  Map<String, SharedMapLocation> build() => const {};

  void record(String chatId, SharedLocation location, {DateTime? sentAt}) {
    if (chatId.isEmpty || chatId.startsWith('#')) return;
    if (location.expired) {
      forget(chatId);
      return;
    }
    state = {
      ...state,
      chatId: SharedMapLocation(
        chatId: chatId,
        location: location,
        sentAt: sentAt ?? DateTime.now(),
      ),
    };
  }

  void forget(String chatId) {
    if (!state.containsKey(chatId)) return;
    state = {...state}..remove(chatId);
  }

  void clear() {
    if (state.isEmpty) return;
    state = const {};
  }
}

final mapPresenceStoreProvider =
    NotifierProvider<MapPresenceStore, Map<String, SharedMapLocation>>(
  MapPresenceStore.new,
);

/// Current map pins: live beacons first, then anything a person deliberately
/// shared in a conversation.
///
/// This provider performs no network work and never requests another person's
/// location. A contact appears only after sending a location themselves, and an
/// expired live-location disappears automatically. A live beacon wins over a
/// hand-shared pin because it is, by construction, the newer of the two.
final sharedMapLocationsProvider =
    Provider<Map<String, SharedMapLocation>>((ref) {
  final history = ref.watch(messagesControllerProvider);
  final beacons = ref.watch(mapPresenceStoreProvider);
  final shared = sharedMapLocationsFromHistory(history);
  if (beacons.isEmpty) return shared;
  return {...shared, ...beacons};
});
@visibleForTesting
Map<String, SharedMapLocation> sharedMapLocationsFromHistory(
  Map<String, List<Message>> history, {
  DateTime? now,
}) {
  final result = <String, SharedMapLocation>{};
  final currentTime = now ?? DateTime.now();

  for (final entry in history.entries) {
    // Channels mix several authors into one bucket, so the chat id cannot be
    // attributed to one avatar. The first map iteration is intentionally 1:1.
    if (entry.key.startsWith('#')) continue;

    for (final message in entry.value.reversed) {
      if (message.isMine || message.kind != MessageKind.text) continue;
      final location = SharedLocation.tryParse(message.text);
      if (location == null) continue;
      // The newest location message decides. Falling back to an older pin after
      // a newer live share expires would silently move the person backwards.
      if (location.expiresAt == null ||
          !currentTime.isAfter(location.expiresAt!)) {
        result[entry.key] = SharedMapLocation(
          chatId: entry.key,
          location: location,
          sentAt: message.sentAt,
        );
      }
      break;
    }
  }

  return result;
}
