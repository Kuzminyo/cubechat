import '../data/message_visibility.dart';
import '../models/message.dart';

/// The message "New messages" is drawn above: the first one in [msgs] that
/// arrived after [lastReadAt] and is somebody else's — the same rule as the
/// unread badge on the chats list (`unreadMessageCount`), so the line and the
/// number there never disagree. Map beacons are skipped for the same reason
/// they are not counted: nobody wrote them.
///
/// Null when nothing is new, and when the chat was never read at all: with no
/// "since" there is nothing to divide, and a line above the whole history —
/// every conversation after a phone transfer — would say nothing.
String? firstUnreadMessageId(List<Message> msgs, DateTime? lastReadAt) {
  if (lastReadAt == null) return null;
  for (final m in msgs) {
    if (m.isMine || isMapBeaconMessage(m)) continue;
    if (m.sentAt.isAfter(lastReadAt)) return m.id;
  }
  return null;
}
