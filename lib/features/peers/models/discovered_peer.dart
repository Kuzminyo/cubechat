import 'package:flutter/foundation.dart';

/// A peer we have seen on the local BLE mesh.
///
/// `id` is the platform device identifier (MAC on Android, opaque UUID on iOS) —
/// it is *not* the cryptographic identity. The cubechat-level identity (Noise
/// static public key) is learned later via the PeerInfo characteristic; until
/// then, `pubkeyFingerprint` stays null.
@immutable
class DiscoveredPeer {
  const DiscoveredPeer({
    required this.id,
    required this.advertisedName,
    required this.rssi,
    required this.lastSeen,
    this.pubkeyFingerprint,
    this.isConnected = false,
    this.rotatingId,
    this.resolvedPubkeyHex,
  });

  /// What the platform reports for an advertisement it has no signal reading
  /// for. It is a sentinel, not a measurement: a real RSSI is negative, and
  /// 127 dBm would be a transmitter you could hear from orbit. Shown as
  /// "unknown" and sorted last rather than treated as the loudest thing in the
  /// room, which is where it used to end up.
  static const int unknownRssi = 127;

  final String id;
  final String advertisedName;
  final int rssi;

  bool get hasSignalReading => rssi < unknownRssi && rssi != 0;
  final DateTime lastSeen;
  final String? pubkeyFingerprint;
  final bool isConnected;

  /// The rotating peer id this device advertised, lowercase hex, or null if it
  /// advertised none (an older build, or one whose identity wasn't ready).
  ///
  /// Stable for one epoch and unlinkable across epochs by anyone who does not
  /// hold the key behind it — which is what makes it safe to broadcast where a
  /// nickname would not be.
  final String? rotatingId;

  /// Who [rotatingId] turned out to be, if it matched somebody in the roster.
  ///
  /// This is the piece that was missing for IK: BLE otherwise tells us nothing
  /// about *who* is advertising until after a handshake, so there was no way to
  /// address an IK opener at them. With this we can, and a contact stays
  /// reachable even when they have stopped announcing themselves.
  final String? resolvedPubkeyHex;

  /// 0..1 signal strength — handy for UI bars. -45 dBm or better → 1.0,
  /// -95 dBm or worse → 0.0.
  double get signalStrength {
    // Unknown reads as weakest, not strongest. Clamping the 127 sentinel to
    // the top of the scale drew four full bars beside the one device we had
    // no measurement for at all.
    if (!hasSignalReading) return 0;
    const min = -95;
    const max = -45;
    final clamped = rssi.clamp(min, max);
    return (clamped - min) / (max - min);
  }

  DiscoveredPeer copyWith({
    String? advertisedName,
    int? rssi,
    DateTime? lastSeen,
    String? pubkeyFingerprint,
    bool? isConnected,
    String? rotatingId,
    String? resolvedPubkeyHex,
  }) {
    return DiscoveredPeer(
      id: id,
      advertisedName: advertisedName ?? this.advertisedName,
      rssi: rssi ?? this.rssi,
      lastSeen: lastSeen ?? this.lastSeen,
      pubkeyFingerprint: pubkeyFingerprint ?? this.pubkeyFingerprint,
      isConnected: isConnected ?? this.isConnected,
      rotatingId: rotatingId ?? this.rotatingId,
      resolvedPubkeyHex: resolvedPubkeyHex ?? this.resolvedPubkeyHex,
    );
  }
}
