import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The last presence beacon we received from one peer.
@immutable
class PeerPresence {
  const PeerPresence({required this.online, required this.at});

  /// What the beacon said: the peer had the app open, or was leaving it.
  final bool online;

  /// When it landed, by our clock.
  final DateTime at;

  /// A beacon is only worth believing for a while: the app can be killed
  /// outright, and the goodbye beacon is best-effort. Two missed heartbeats
  /// ([MessagingService.presenceHeartbeat] is 45 s) is the window, matching how
  /// the mesh treats a missed announcement.
  static const Duration ttl = Duration(seconds: 150);

  bool get isFresh => DateTime.now().difference(at) < ttl;

  @override
  bool operator ==(Object other) =>
      other is PeerPresence && other.online == online && other.at == at;

  @override
  int get hashCode => Object.hash(online, at);
}

/// Who is currently in the app, keyed by canonical chat id (pubkey-hex).
///
/// Deliberately memory-only: presence is worth nothing after a restart, and
/// persisting "who was online when" would be storing exactly the metadata this
/// app exists to avoid. It fills the gap the mesh can't: BLE announcements say
/// "in range", and two people talking over the internet are never in range, so
/// without this a peer chatting from another city always read as offline.
class PresenceController extends Notifier<Map<String, PeerPresence>> {
  @override
  Map<String, PeerPresence> build() => const <String, PeerPresence>{};

  /// Record a beacon from [canonicalId]. Out-of-order beacons are ignored — a
  /// stale "offline" arriving after a fresh "online" must not flip the dot.
  void record(String canonicalId, {required bool online, DateTime? at}) {
    final stamp = at ?? DateTime.now();
    final existing = state[canonicalId];
    if (existing != null && existing.at.isAfter(stamp)) return;
    state = {
      ...state,
      canonicalId: PeerPresence(online: online, at: stamp),
    };
  }

  /// Presence for [canonicalId] while it's still fresh, else null so the caller
  /// falls back to mesh evidence (a live session, or the last announcement).
  PeerPresence? freshFor(String canonicalId) {
    final p = state[canonicalId];
    if (p == null || !p.isFresh) return null;
    return p;
  }

  void clear() => state = const <String, PeerPresence>{};
}

final presenceControllerProvider =
    NotifierProvider<PresenceController, Map<String, PeerPresence>>(
  PresenceController.new,
);

/// How long after an announcement a peer still counts as mesh-reachable. Peers
/// re-announce every 60 s, so ~2.5 ticks absorbs one missed beacon.
const Duration kMeshPresenceWindow = Duration(seconds: 150);

/// Whether a peer should read as "in the app", given everything we know.
///
/// Pulled out of the chat header because the precedence is the whole feature and
/// it is easy to get subtly wrong:
///
///   * A live Noise session is definite — it can only exist while both ends are
///     running.
///   * Otherwise a *fresh* beacon decides, including a "going away" one. This is
///     what covers peers reachable only over the internet, and it has to beat
///     the window below: a beacon arriving over a relay also refreshes
///     `lastSeen`, so falling through would keep claiming "online" for another
///     two minutes after they closed the app.
///   * With no beacon we're back to mesh evidence: were they announcing
///     recently.
bool peerIsOnline({
  required bool hasLiveSession,
  required PeerPresence? beacon,
  required DateTime? lastSeen,
  DateTime? now,
}) {
  if (hasLiveSession) return true;
  final at = now ?? DateTime.now();
  if (beacon != null && at.difference(beacon.at) < PeerPresence.ttl) {
    return beacon.online;
  }
  return lastSeen != null && at.difference(lastSeen) < kMeshPresenceWindow;
}
