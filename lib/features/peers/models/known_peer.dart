import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// A peer we have at some point authenticated through a Noise XX handshake.
///
/// The identity is the **pubkey fingerprint** (lowercase hex of the X25519
/// static public key) — that's the same across BLE Privacy address rotations,
/// transport disconnects, and app restarts. The display name is whatever the
/// peer advertised on BLE the last time we saw them.
///
/// [signPublicKey] is the Ed25519 verifying key learned from a signed peer
/// announcement; once cached, every subsequent signed message body is
/// verified against it. Null when we only know the peer from a direct
/// Noise handshake that predates the signed-announcement upgrade.
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
    this.signPublicKey,
    this.signKeyRotatedAt,
  });

  final String pubkeyHex;
  final String displayName;
  final DateTime lastSeen;
  final DateTime? verifiedAt;
  final Uint8List? signPublicKey;

  /// When this peer's signing key last changed under the same pubkeyHex.
  /// Set the moment a fresh signed announcement arrives carrying a
  /// different Ed25519 public key than the one we'd previously cached;
  /// `verifiedAt` is cleared at the same time, so the chat tile flips
  /// from "verified" to "key changed — re-verify".
  final DateTime? signKeyRotatedAt;

  bool get isVerified => verifiedAt != null;

  /// True between a key rotation and the user's next manual verification.
  /// UI surfaces this as an amber warning over the avatar.
  bool get hasUnacknowledgedRotation =>
      signKeyRotatedAt != null &&
      (verifiedAt == null ||
          verifiedAt!.isBefore(signKeyRotatedAt!));

  KnownPeer copyWith({
    String? displayName,
    DateTime? lastSeen,
    DateTime? verifiedAt,
    Uint8List? signPublicKey,
    DateTime? signKeyRotatedAt,
    bool clearVerifiedAt = false,
    bool clearSignKeyRotatedAt = false,
  }) {
    return KnownPeer(
      pubkeyHex: pubkeyHex,
      displayName: displayName ?? this.displayName,
      lastSeen: lastSeen ?? this.lastSeen,
      verifiedAt: clearVerifiedAt ? null : (verifiedAt ?? this.verifiedAt),
      signPublicKey: signPublicKey ?? this.signPublicKey,
      signKeyRotatedAt: clearSignKeyRotatedAt
          ? null
          : (signKeyRotatedAt ?? this.signKeyRotatedAt),
    );
  }
}
