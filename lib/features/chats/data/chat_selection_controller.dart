import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The chats currently picked out in the list.
///
/// Long-pressing a row no longer opens a menu about that one row: it selects
/// it, the header becomes a bar of actions, and every further tap adds or
/// removes a row. That is what the rest of the world's chat lists do, and the
/// reason is that the interesting operations — pin these four, mute these two,
/// clear these — are all plural, and a per-row menu can only ever do them one
/// at a time.
///
/// Session state, deliberately not persisted: a selection is a thing somebody
/// is doing right now, and finding one waiting after a restart would be a
/// puzzle rather than a convenience.
class ChatSelectionController extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  bool get isActive => state.isNotEmpty;

  bool contains(String chatId) => state.contains(chatId);

  void toggle(String chatId) {
    final next = {...state};
    if (!next.remove(chatId)) next.add(chatId);
    state = next;
  }

  void select(String chatId) {
    if (state.contains(chatId)) return;
    state = {...state, chatId};
  }

  void clear() {
    if (state.isEmpty) return;
    state = const <String>{};
  }

  /// Forget ids that no longer name a chat.
  ///
  /// The bar counts the rows it can see, and selection mode is on whenever this
  /// set is not empty — so the instant an action takes the last picked
  /// conversation off the list, the two disagree, and the header sits there in
  /// selection mode reading "0". Deleting a chat left it that way until the
  /// close button was found and pressed.
  ///
  /// Handlers do clear the selection when their work finishes and this does not
  /// replace that. It covers the gap between the row going and the work
  /// returning — nine storage steps for one delete — and the handlers that take
  /// an early exit before reaching their own clear.
  void retainOnly(Set<String> live) {
    if (state.isEmpty) return;
    final next = {
      for (final id in state)
        if (live.contains(id)) id,
    };
    if (next.length == state.length) return;
    state = next;
  }
}

final chatSelectionProvider =
    NotifierProvider<ChatSelectionController, Set<String>>(
  ChatSelectionController.new,
);
