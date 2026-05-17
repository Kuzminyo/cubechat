import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/known_peer.dart';

/// Persistent (within app lifetime — disk persistence lands in M4) roster of
/// peers we have successfully authenticated through Noise XX.
///
/// Keyed by pubkeyHex (the hex of the peer's X25519 static public key) — that
/// id stays stable across BLE Privacy address rotations and transport
/// disconnects, so a chat with a friend stays put in the main Chats list even
/// after they walk out of range.
class KnownPeersController extends Notifier<Map<String, KnownPeer>> {
  @override
  Map<String, KnownPeer> build() => <String, KnownPeer>{};

  /// Register a peer (or refresh display name / lastSeen on an existing one).
  void upsert({
    required String pubkeyHex,
    required String displayName,
  }) {
    final now = DateTime.now();
    final existing = state[pubkeyHex];
    final entry = existing == null
        ? KnownPeer(
            pubkeyHex: pubkeyHex,
            displayName: displayName,
            lastSeen: now,
          )
        : existing.copyWith(
            displayName: displayName.isNotEmpty ? displayName : existing.displayName,
            lastSeen: now,
          );
    state = {...state, pubkeyHex: entry};
  }

  /// Forget every known peer — used by the Emergency Wipe flow.
  void clear() {
    state = <String, KnownPeer>{};
  }

  /// Drop a single peer (the user removed a chat from the list).
  void forget(String pubkeyHex) {
    if (!state.containsKey(pubkeyHex)) return;
    state = {...state}..remove(pubkeyHex);
  }
}

final knownPeersControllerProvider =
    NotifierProvider<KnownPeersController, Map<String, KnownPeer>>(
  KnownPeersController.new,
);
