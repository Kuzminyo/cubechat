import 'package:flutter/foundation.dart';

import '../models/message.dart';

/// Everything the chat list needs about a conversation, without the
/// conversation.
///
/// A row asks history two questions and no others: what was the last thing
/// said, and how many incoming messages are newer than the read marker. Both
/// answers fit in a record small enough to read at startup for every chat at
/// once, which is the whole point — a list drawn from full history costs the
/// history, and the history is the part that grows.
///
/// The unread side is stored as the arrival times of incoming messages rather
/// than as a count, because the count is not a property of the conversation:
/// it is a property of the conversation *and* the read marker, and the marker
/// moves without any message changing. Times are cheap — eight bytes each,
/// no decoding, no objects — so a chat of six thousand messages carries a few
/// tens of kilobytes here against megabytes there.
@immutable
class ChatSummary {
  const ChatSummary({required this.last, required this.incomingAtMs});

  /// The newest message worth showing as a preview, or null if the
  /// conversation holds nothing visible.
  final Message? last;

  /// When each incoming message was sent, ascending. Only messages that can be
  /// unread: not ours, and not a map beacon.
  ///
  /// All of them, not just the ones currently unread. Keeping only the unread
  /// tail would need the read marker, which lives in another controller and
  /// moves on its own — and a summary that depends on something it cannot see
  /// is a summary that goes quietly wrong. Every timestamp costs eight bytes
  /// and no decoding, so a conversation of six thousand messages carries a few
  /// tens of kilobytes here against several megabytes of history.
  ///
  /// Sorted rather than in arrival order: `sentAt` is the sender's clock, and a
  /// relay hands over a backlog whenever it reconnects, so the order messages
  /// arrive in is not the order they were written in. [unreadAfter] needs the
  /// sorted one.
  final List<int> incomingAtMs;

  /// How many of those are newer than [lastReadAt].
  ///
  /// Binary search rather than a walk: this runs once per conversation on
  /// every rebuild of the list, and the list rebuilds on a keystroke in the
  /// composer.
  int unreadAfter(DateTime? lastReadAt) {
    if (incomingAtMs.isEmpty) return 0;
    if (lastReadAt == null) return incomingAtMs.length;
    final marker = lastReadAt.millisecondsSinceEpoch;
    var low = 0;
    var high = incomingAtMs.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (incomingAtMs[mid] > marker) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    return incomingAtMs.length - low;
  }

  @override
  bool operator ==(Object other) =>
      other is ChatSummary &&
      identical(other.last, last) &&
      identical(other.incomingAtMs, incomingAtMs);

  @override
  int get hashCode => Object.hash(identityHashCode(last), incomingAtMs.length);
}
