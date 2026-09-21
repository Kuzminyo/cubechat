import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chats/data/saved_messages.dart';
import '../models/message.dart';
import 'messages_controller.dart';

/// One of our messages that found no road and is held until one opens.
@immutable
class QueuedMessage {
  const QueuedMessage({required this.chatId, required this.message});

  /// The conversation it sits in, which is what the queue opens and names.
  final String chatId;
  final Message message;
}

/// Everything of ours still waiting for Bluetooth or the internet, oldest
/// first.
///
/// "Waiting" is exactly what the bubble shows as waiting: still sending, and
/// filed as `queued` because nothing carried it when it was sent. A message on
/// its way right now is not in here — it is not waiting for a connection, it
/// is using one.
///
/// Only the tail of each conversation is read. Anything held longer than a
/// day is in the conversation's last few hundred messages or nowhere — the
/// store gives up on a frame long before — and reading every message of every
/// chat on each change of the message store is the cost this avoids: that
/// store changes on every tick that turns grey to blue.
List<QueuedMessage> queuedMessages(
  Map<String, List<Message>> byChat, {
  int tail = 300,
}) {
  final seen = <String>{};
  final out = <QueuedMessage>[];
  for (final entry in byChat.entries) {
    if (isSavedChat(entry.key)) continue;
    final list = entry.value;
    for (var i = list.length - 1; i >= 0 && i >= list.length - tail; i--) {
      final m = list[i];
      if (!m.isMine ||
          m.status != MessageStatus.sending ||
          m.route != MessageRoute.queued) {
        continue;
      }
      // A message can sit under two keys while a legacy address bucket is
      // folded into the peer's own; it is one message waiting, not two.
      if (!seen.add(m.id)) continue;
      out.add(QueuedMessage(chatId: entry.key, message: m));
    }
  }
  out.sort((a, b) => a.message.sentAt.compareTo(b.message.sentAt));
  return out;
}

final sendQueueProvider = Provider<List<QueuedMessage>>(
  (ref) => queuedMessages(ref.watch(messagesControllerProvider)),
);
