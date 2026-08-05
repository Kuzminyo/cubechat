import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which messages are ticked in a chat, keyed by chat id.
///
/// An empty set *is* "not selecting", so there is no second boolean to keep in
/// step with it. Family-scoped and auto-disposing like the other per-chat
/// scratch state ([chatHighlightProvider], the search-open flag): leaving the
/// conversation ends the selection, which is what anyone would expect from a
/// mode entered by long-pressing one message.
final messageSelectionProvider =
    NotifierProvider.autoDispose.family<MessageSelection, Set<String>, String>(
  MessageSelection.new,
);

class MessageSelection extends AutoDisposeFamilyNotifier<Set<String>, String> {
  @override
  Set<String> build(String arg) => const <String>{};

  bool get isActive => state.isNotEmpty;

  bool contains(String messageId) => state.contains(messageId);

  /// Tick or untick one message. Unticking the last one leaves selection mode,
  /// which is the same gesture as cancelling — no separate exit needed.
  void toggle(String messageId) {
    final next = {...state};
    if (!next.remove(messageId)) next.add(messageId);
    state = next;
  }

  void start(String messageId) => state = {messageId};

  void clear() => state = const <String>{};
}
