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
}

final chatSelectionProvider =
    NotifierProvider<ChatSelectionController, Set<String>>(
  ChatSelectionController.new,
);
