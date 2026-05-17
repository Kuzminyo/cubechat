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
  ///
  /// `displayName` precedence: a real BLE-advertised name beats the responder
  /// placeholder `Peer XX:XX:`. Without this, whichever handshake direction
  /// finishes last would overwrite the proper name with the placeholder.
  void upsert({
    required String pubkeyHex,
    required String displayName,
  }) {
    final now = DateTime.now();
    final existing = state[pubkeyHex];

    final newIsPlaceholder = displayName.startsWith('Peer ');
    final String resolvedName;
    if (existing == null) {
      resolvedName = displayName;
    } else if (newIsPlaceholder && existing.displayName.isNotEmpty &&
        !existing.displayName.startsWith('Peer ')) {
      // Existing name is real, incoming is the responder placeholder — keep
      // the real one.
      resolvedName = existing.displayName;
    } else if (displayName.isEmpty) {
      resolvedName = existing.displayName;
    } else {
      resolvedName = displayName;
    }

    final entry = KnownPeer(
      pubkeyHex: pubkeyHex,
      displayName: resolvedName,
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
