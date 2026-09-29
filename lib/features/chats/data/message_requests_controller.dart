import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

@immutable
class MessageRequests {
  const MessageRequests({
    this.pending = const <String>{},
    this.accepted = const <String>{},
  });

  /// Strangers whose first message is waiting in the Requests drawer.
  final Set<String> pending;

  /// Strangers whose request was accepted: contacts from now on, even though
  /// this phone may never have written to them.
  final Set<String> accepted;

  static const empty = MessageRequests();
}

/// Who is waiting in Requests, and who was let in.
///
/// Filled by the inbound path at the moment a stranger's message arrives
/// (see `strangerVerdict`), never worked out later from history: on a cold
/// start the history is not loaded yet, and the list would fold every chat
/// into Requests on its first frame. Stored like [ArchivedChatsController]
/// stores its set — merged under what is in memory, a write before the box
/// opened kept for when it does.
class MessageRequestsController extends Notifier<MessageRequests> {
  static const _keyPending = 'requests.pending';
  static const _keyAccepted = 'requests.accepted';

  Box<dynamic>? _box;
  Future<void>? _loading;
  bool _writePending = false;

  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  MessageRequests build() {
    unawaited(_loading = _load());
    return MessageRequests.empty;
  }

  static Set<String> _read(Box<dynamic> box, String key) {
    final raw = box.get(key);
    return raw is List ? raw.whereType<String>().toSet() : <String>{};
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final pending = _read(box, _keyPending);
      final accepted = _read(box, _keyAccepted);
      if (pending.isNotEmpty || accepted.isNotEmpty) {
        state = MessageRequests(
          pending: {...pending, ...state.pending}
            ..removeAll({...accepted, ...state.accepted}),
          accepted: {...accepted, ...state.accepted},
        );
      }
    } catch (e) {
      debugPrint('MessageRequestsController load failed: $e');
    }
    if (_writePending && _box != null) {
      _writePending = false;
      await _persist();
    }
  }

  bool isPending(String peer) => state.pending.contains(peer);

  Future<void> markPending(String peer) async {
    if (state.pending.contains(peer) || state.accepted.contains(peer)) return;
    state = MessageRequests(
      pending: {...state.pending, peer},
      accepted: state.accepted,
    );
    await _persist();
  }

  /// Let them in: out of the drawer, and never a request again.
  Future<void> accept(String peer) async {
    if (!state.pending.contains(peer) && state.accepted.contains(peer)) return;
    state = MessageRequests(
      pending: {...state.pending}..remove(peer),
      accepted: {...state.accepted, peer},
    );
    await _persist();
  }

  /// Forget them either way — after "Delete" or "Block".
  Future<void> drop(String peer) async {
    if (!state.pending.contains(peer) && !state.accepted.contains(peer)) {
      return;
    }
    state = MessageRequests(
      pending: {...state.pending}..remove(peer),
      accepted: {...state.accepted}..remove(peer),
    );
    await _persist();
  }

  /// The setting went back to "everyone": every waiting chat becomes an
  /// ordinary one.
  Future<void> clearPending() async {
    if (state.pending.isEmpty) return;
    state = MessageRequests(accepted: state.accepted);
    await _persist();
  }

  Future<void> clear() async {
    state = MessageRequests.empty;
    await _persist();
  }

  Future<void> _persist() async {
    final box = _box;
    if (box == null) {
      _writePending = true;
      return;
    }
    try {
      await box.put(_keyPending, state.pending.toList());
      await box.put(_keyAccepted, state.accepted.toList());
    } catch (e) {
      debugPrint('MessageRequestsController persist failed: $e');
    }
  }
}

final messageRequestsProvider =
    NotifierProvider<MessageRequestsController, MessageRequests>(
  MessageRequestsController.new,
);
