import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Messages that are on their way out, so the list can play them out rather
/// than snap.
///
/// Deleting rewrote the message list and the row was simply gone on the next
/// frame — the rest of the conversation jumped up to fill the gap with nothing
/// to say what had happened. It reads as a glitch rather than as an action,
/// and it is worse the more you delete at once: thirty rows vanish and the
/// scrollback lurches.
///
/// The list cannot animate a removal it is only told about afterwards, so the
/// order is inverted: mark first, remove when the animation has finished. The
/// ids sit here for exactly that long. Everything that deletes goes through
/// [dismiss] — our own delete, a batch of them, and a peer's "delete for
/// everyone", which is the one people watch happen.
class MessageFarewell extends FamilyNotifier<Set<String>, String> {
  /// Long enough to read as leaving, short enough that deleting thirty
  /// messages is not a wait. The list keeps its gesture responsive throughout,
  /// so this is never in anybody's way.
  static const Duration duration = Duration(milliseconds: 220);

  @override
  Set<String> build(String arg) => const <String>{};

  /// Play [ids] out, then run [remove].
  ///
  /// [remove] is the actual deletion, handed in rather than performed here: a
  /// message leaves for several different reasons — locally, for everyone, on
  /// a peer's say-so — and this class has no business knowing which.
  Future<void> dismiss(Set<String> ids, void Function() remove) async {
    if (ids.isEmpty) {
      remove();
      return;
    }
    state = {...state, ...ids};
    await Future<void>.delayed(duration);
    try {
      // The deletion happens whatever became of this screen in the meantime.
      // Leaving the conversation mid-animation must not leave the message
      // undeleted — the user asked for it to go.
      remove();
    } finally {
      // Unmarked even if the removal threw. A mark that outlives its animation
      // is worse than a failed delete: the row stays collapsed to nothing, so
      // the message looks deleted, is still there, and comes back at the next
      // launch with no way to tell what happened.
      try {
        state = state.difference(ids);
      } catch (_) {
        // The notifier was disposed while the animation played, which only
        // means nobody is looking at the set any more.
      }
    }
  }
}

final messageFarewellProvider =
    NotifierProvider.family<MessageFarewell, Set<String>, String>(
  MessageFarewell.new,
);
