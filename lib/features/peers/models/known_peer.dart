import 'package:flutter/foundation.dart';

/// A peer we have at some point authenticated through a Noise XX handshake.
///
/// The identity is the **pubkey fingerprint** (lowercase hex of the X25519
/// static public key) — that's the same across BLE Privacy address rotations,
/// transport disconnects, and app restarts. The display name is whatever the
/// peer advertised on BLE the last time we saw them.
@immutable
class KnownPeer {
  const KnownPeer({
    required this.pubkeyHex,
    required this.displayName,
    required this.lastSeen,
  });

  final String pubkeyHex;
  final String displayName;
  final DateTime lastSeen;

  KnownPeer copyWith({String? displayName, DateTime? lastSeen}) {
    return KnownPeer(
      pubkeyHex: pubkeyHex,
      displayName: displayName ?? this.displayName,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}
