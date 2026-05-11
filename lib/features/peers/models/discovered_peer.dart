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
  });

  final String id;
  final String advertisedName;
  final int rssi;
  final DateTime lastSeen;
  final String? pubkeyFingerprint;
  final bool isConnected;

  /// 0..1 signal strength — handy for UI bars. -45 dBm or better → 1.0,
  /// -95 dBm or worse → 0.0.
  double get signalStrength {
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
  }) {
    return DiscoveredPeer(
      id: id,
      advertisedName: advertisedName ?? this.advertisedName,
      rssi: rssi ?? this.rssi,
      lastSeen: lastSeen ?? this.lastSeen,
      pubkeyFingerprint: pubkeyFingerprint ?? this.pubkeyFingerprint,
      isConnected: isConnected ?? this.isConnected,
    );
  }
}
