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

/// Current map pins derived from existing encrypted chat history.
///
/// This provider performs no network work and never requests another person's
/// location. A contact appears only after sending a location message
/// themselves, and an expired live-location message disappears automatically.
final sharedMapLocationsProvider =
    Provider<Map<String, SharedMapLocation>>((ref) {
  final history = ref.watch(messagesControllerProvider);
  return sharedMapLocationsFromHistory(history);
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
