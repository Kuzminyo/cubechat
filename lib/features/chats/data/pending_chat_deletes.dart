import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Conversations deleted a moment ago that can still be taken back.
///
/// Deleting a chat used to happen the instant the dialog was answered: nine
/// storage steps, and — with "delete for them too" ticked — a retraction sent
/// to the other phone, none of which a mis-tap could undo. Asked for the way
/// Telegram does it: the row goes at once, a toast counts down five seconds
/// with an Undo on it, and only when it runs out does anything happen.
///
/// So a delete is *held*: its id is in this set, which the chat list filters
/// on, and the work that removes it waits in [_commits]. [undo] drops the work
/// and the row comes back where it was; [commit] runs it. Nothing about the
/// conversation has changed until then — not on this phone, not on theirs.
///
/// The app leaving the screen commits everything held. A toast counting down
/// in a backgrounded app is a promise nobody is watching, and a process killed
/// there would otherwise quietly bring back chats the owner deleted.
class PendingChatDeletes extends Notifier<Set<String>>
    with WidgetsBindingObserver {
  final Map<String, Future<void> Function()> _commits = {};

  @override
  Set<String> build() {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() => WidgetsBinding.instance.removeObserver(this));
    return const <String>{};
  }

  /// [chatId] is deleted as far as anyone looking is concerned; [commit] is
  /// what actually deletes it, later.
  ///
  /// Holding a chat that is already held replaces the work — the later answer
  /// to the dialog is the one that stands.
  void hold(String chatId, Future<void> Function() commit) {
    _commits[chatId] = commit;
    if (!state.contains(chatId)) state = {...state, chatId};
  }

  /// Take it back. False when there was nothing held — it had already been
  /// committed, or was never deleted.
  bool undo(String chatId) {
    if (_commits.remove(chatId) == null) return false;
    state = {...state}..remove(chatId);
    return true;
  }

  /// Do the delete now.
  ///
  /// The id leaves the set only once the work is done, so the row does not
  /// flash back between "no longer held" and "actually gone".
  Future<void> commit(String chatId) async {
    final run = _commits.remove(chatId);
    if (run == null) return;
    try {
      await run();
    } finally {
      if (!_commits.containsKey(chatId) && state.contains(chatId)) {
        state = {...state}..remove(chatId);
      }
    }
  }

  /// Everything held, now.
  Future<void> commitAll() async {
    for (final chatId in [..._commits.keys]) {
      await commit(chatId);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.detached) {
      unawaited(commitAll());
    }
  }
}

final pendingChatDeletesProvider =
    NotifierProvider<PendingChatDeletes, Set<String>>(PendingChatDeletes.new);
