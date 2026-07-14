import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The message the composer is currently quoting (a reply), or null.
///
/// Mirrors [MessageEditTarget]: set by a bubble's long-press "Reply" action,
/// read by the chat's input row, which shows a preview bar and passes the
/// quoted message's wireId to `sendText(replyToWireId:)`. Lives in a provider
/// because the bubble (deep in the list) and the input row (at the bottom)
/// have no direct handle on each other.
@immutable
class MessageReplyTarget {
  const MessageReplyTarget({
    required this.chatId,
    required this.wireId,
    required this.preview,
    this.mine = false,
    this.authorName,
  });

  /// The chat this message lives in (pubkey-hex peer id or `#channel`).
  final String chatId;

  /// The transport id the quoted message was filed under.
  final String wireId;

  /// A short snippet of the quoted message, for the preview bar.
  final String preview;

  /// True when quoting the local user's own message.
  final bool mine;

  /// Display name of the quoted author (channels), or null in 1:1.
  final String? authorName;
}

final messageReplyTargetProvider =
    StateProvider<MessageReplyTarget?>((_) => null);
