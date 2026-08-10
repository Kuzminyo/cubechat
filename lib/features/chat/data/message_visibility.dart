import '../../../core/transport/shared_location.dart';
import '../models/message.dart';

/// Is this stored message a map presence beacon rather than something a person
/// meant to say?
///
/// Beacons no longer reach history at all — they are intercepted on arrival and
/// kept in memory (see `MapPresenceStore`). This exists for the ones an older
/// build already wrote there: one every forty-five seconds, per map friend, for
/// as long as anybody had the map open. Left visible they bury the actual
/// conversation, and the chat list claims the last thing said was a base64 URI.
bool isMapBeaconMessage(Message message) =>
    message.kind == MessageKind.text &&
    SharedLocation.isBeaconText(message.text, message.sentAt);

/// The conversation with the beacons taken out.
List<Message> visibleMessages(List<Message> messages) {
  if (!messages.any(isMapBeaconMessage)) return messages;
  return [
    for (final message in messages)
      if (!isMapBeaconMessage(message)) message,
  ];
}

/// The newest message worth showing as a preview, or null if there is none.
Message? lastVisibleMessage(List<Message> messages) {
  for (var i = messages.length - 1; i >= 0; i--) {
    final message = messages[i];
    if (!isMapBeaconMessage(message)) return message;
  }
  return null;
}
