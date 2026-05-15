import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../crypto/identity_service.dart';
import 'chat_session.dart';

/// Riverpod-managed map of `peerId → ChatSession`.
///
/// Lives for the app's lifetime; sessions inside it are in-memory only and
/// don't survive an app restart. Persistence lands with the M4 storage
/// milestone.
class ChatSessionManager extends Notifier<Map<String, ChatSession>> {
  @override
  Map<String, ChatSession> build() {
    ref.onDispose(_disposeAll);
    return <String, ChatSession>{};
  }

  ChatSession? sessionFor(String peerId) => state[peerId];

  /// Creates a fresh initiator-side session. Used right after the user taps
  /// "Connect" on a discovered peer.
  Future<ChatSession> startInitiator(String peerId, {required String peerLabel}) async {
    final existing = state[peerId];
    if (existing != null && existing.status != ChatSessionStatus.failed) {
      return existing;
    }
    final identity = await ref.read(identityProvider.future);
    final session = await ChatSession.initiate(
      peerId: peerId,
      peerLabel: peerLabel,
      identity: identity,
    );
    state = {...state, peerId: session};
    return session;
  }

  /// Creates a fresh responder-side session. Used when our peripheral receives
  /// the first handshake byte stream from an unknown central.
  Future<ChatSession> startResponder(String peerId, {String? peerLabel}) async {
    final existing = state[peerId];
    if (existing != null && existing.status != ChatSessionStatus.failed) {
      return existing;
    }
    final identity = await ref.read(identityProvider.future);
    final session = await ChatSession.respond(
      peerId: peerId,
      peerLabel: peerLabel ?? 'Peer ${peerId.substring(0, peerId.length.clamp(0, 6))}',
      identity: identity,
    );
    state = {...state, peerId: session};
    return session;
  }

  /// Tear down the session for [peerId] — used on transport disconnect, on
  /// emergency wipe, or when we see a RESET frame from the peer.
  void drop(String peerId) {
    final s = state[peerId];
    if (s == null) return;
    try {
      s.destroy();
    } catch (e, st) {
      debugPrint('ChatSession.destroy failed for $peerId: $e\n$st');
    }
    state = {...state}..remove(peerId);
  }

  /// Returns true if the session for [peerId] is fully established.
  bool isEstablished(String peerId) => state[peerId]?.isEstablished ?? false;

  /// Triggers a state rebuild — callers should invoke this after mutating
  /// a ChatSession's internal status, since Notifier only repushes when
  /// `state =` is reassigned.
  void touch(String peerId) {
    if (!state.containsKey(peerId)) return;
    state = {...state};
  }

  void _disposeAll() {
    for (final s in state.values) {
      try {
        s.destroy();
      } catch (_) {
        // ignore
      }
    }
  }
}

final chatSessionManagerProvider =
    NotifierProvider<ChatSessionManager, Map<String, ChatSession>>(ChatSessionManager.new);
