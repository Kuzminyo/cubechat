import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The message currently being edited inline, or null when not editing.
///
/// Set by a message bubble's long-press "Edit" action and read by the chat's
/// input row, which loads the text and commits the change on send. Kept in a
/// provider because the bubble (deep in the list) and the input row (at the
/// bottom) are siblings with no direct handle on each other.
@immutable
class MessageEditTarget {
  const MessageEditTarget({
    required this.chatId,
    required this.wireId,
    required this.originalText,
  });

  /// The chat this message lives in (pubkey-hex peer id or `#channel`).
  final String chatId;

  /// The transport id everyone filed the message under — what the edit
  /// references on the wire.
  final String wireId;

  final String originalText;
}

final messageEditTargetProvider =
    StateProvider<MessageEditTarget?>((_) => null);
