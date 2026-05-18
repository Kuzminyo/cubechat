import 'package:flutter/foundation.dart';

/// A peer we have at some point authenticated through a Noise XX handshake.
///
/// The identity is the **pubkey fingerprint** (lowercase hex of the X25519
/// static public key) — that's the same across BLE Privacy address rotations,
/// transport disconnects, and app restarts. The display name is whatever the
/// peer advertised on BLE the last time we saw them.
///
/// [verifiedAt] is set the moment the user has compared this peer's fingerprint
/// out-of-band (over a voice call, in person, etc.) and confirmed it matches.
/// A verified peer's chat tile gets a shield-with-check badge so the user can
/// tell at a glance that this is the same person across address rotations.
@immutable
class KnownPeer {
  const KnownPeer({
    required this.pubkeyHex,
    required this.displayName,
    required this.lastSeen,
    this.verifiedAt,
  });

  final String pubkeyHex;
  final String displayName;
  final DateTime lastSeen;
  final DateTime? verifiedAt;

  bool get isVerified => verifiedAt != null;

  KnownPeer copyWith({
    String? displayName,
    DateTime? lastSeen,
    DateTime? verifiedAt,
    bool clearVerifiedAt = false,
  }) {
    return KnownPeer(
      pubkeyHex: pubkeyHex,
      displayName: displayName ?? this.displayName,
      lastSeen: lastSeen ?? this.lastSeen,
      verifiedAt: clearVerifiedAt ? null : (verifiedAt ?? this.verifiedAt),
    );
  }
}
