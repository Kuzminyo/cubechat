import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The last presence beacon we received from one peer.
@immutable
class PeerPresence {
  const PeerPresence({
    required this.online,
    required this.at,
    this.hidesLastSeen = false,
  });

  /// What the beacon said: the peer had the app open, or was leaving it.
  final bool online;

  /// When it landed, by our clock.
  final DateTime at;

  /// They asked not to be shown a clock: their switch is off, so we say
  /// whether they are here but never when they were.
  ///
  /// A request rather than an enforcement — see [PresenceBeacon]. Honouring it
  /// is what the same switch on this phone would want from theirs.
  final bool hidesLastSeen;

  /// A beacon is only worth believing for a while: the app can be killed
  /// outright, and the goodbye beacon is best-effort. Two heartbeats
  /// ([MessagingService.presenceHeartbeat] is 70 s) fit inside this window with
  /// room to spare, so one dropped beacon does not dim a peer who is still
  /// there — the same margin the mesh gives a missed announcement.
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
  /// Drops entries once they are past [PeerPresence.ttl].
  ///
  /// Freshness is a question about the clock, and this state only ever changed
  /// when a beacon *arrived*. A peer who goes quiet sends nothing by
  /// definition — so nothing changed, nothing rebuilt, and the screen went on
  /// showing whatever it had last computed. Reported as somebody reading "in
  /// the app" five minutes after leaving it, which the 150-second window
  /// should have ended long before.
  ///
  /// A stale entry is removed rather than marked: `freshFor` already answers
  /// null for anything expired and every caller falls back to mesh evidence,
  /// so absence is the answer the readers were written for.
  Timer? _sweep;

  /// Half a minute is the most staleness this can leave, against a window of
  /// two and a half.
  static const Duration _sweepEvery = Duration(seconds: 30);

  /// Beacons arrived but not yet published to watchers.
  ///
  /// A relay hands over its backlog in one go, and every beacon in it is newer
  /// than the last, so each passes the ordering guard and each used to be a
  /// separate `state =`. A shared log caught thirteen presence events inside
  /// one second — 18:05:50.294 through .347 — all about the same person, whose
  /// dot flickered online, offline, online while the whole chat list rebuilt
  /// behind it. The frame panel from the same session read build 18.7 ms
  /// against raster 1.3 ms: the cost was entirely in rebuilding, and the GPU
  /// was idle.
  ///
  /// Seven of those thirteen changed the answer. All seven produced the same
  /// final value, which is the only one anybody could perceive.
  final Map<String, PeerPresence> _pending = <String, PeerPresence>{};
  Timer? _publish;

  /// Long enough to swallow a backlog, short enough to be nothing.
  ///
  /// The bursts in that log spanned about fifty milliseconds. A hundred covers
  /// one comfortably and is below what a person reads as delay in a dot that
  /// answers "are they there" — a question already answered on a 150-second
  /// window, so a tenth of a second of latency changes nothing about it.
  static const Duration _coalesceWindow = Duration(milliseconds: 100);

  @override
  Map<String, PeerPresence> build() {
    ref.onDispose(() {
      _sweep?.cancel();
      _sweep = null;
      _publish?.cancel();
      _publish = null;
      _pending.clear();
    });
    return const <String, PeerPresence>{};
  }

  /// Runs only while there is something that can expire, and stops itself once
  /// the map is empty — so a phone with nobody online keeps no timer at all.
  void _ensureSweeping() {
    if (_sweep != null || state.isEmpty) return;
    _sweep = Timer.periodic(_sweepEvery, (_) {
      final live = <String, PeerPresence>{
        for (final e in state.entries)
          if (e.value.isFresh) e.key: e.value,
      };
      if (live.length != state.length) state = live;
      if (state.isEmpty) {
        _sweep?.cancel();
        _sweep = null;
      }
    });
  }

  /// Record a beacon from [canonicalId]. Out-of-order beacons are ignored — a
  /// stale "offline" arriving after a fresh "online" must not flip the dot.
  void record(
    String canonicalId, {
    required bool online,
    bool hidesLastSeen = false,
    DateTime? at,
  }) {
    final stamp = at ?? DateTime.now();
    // Against what is pending as well as what is published, or the ordering
    // guard would only see half the history during a burst.
    final existing = _pending[canonicalId] ?? state[canonicalId];
    if (existing != null && existing.at.isAfter(stamp)) return;
    final beacon = PeerPresence(
      online: online,
      at: stamp,
      hidesLastSeen: hidesLastSeen,
    );

    // The first of a burst goes out at once; the rest of it waits.
    //
    // Coalescing everything would have made a single beacon — the ordinary
    // case, somebody opening the app — a tenth of a second late for no gain,
    // since there is nothing to collapse it with. Publishing on the leading
    // edge keeps that instant and still turns a thirteen-event backlog into
    // two changes instead of thirteen.
    if (_publish == null) {
      _publish = Timer(_coalesceWindow, _publishPending);
      state = {...state, canonicalId: beacon};
      _ensureSweeping();
      return;
    }
    _pending[canonicalId] = beacon;
  }

  /// Hand whatever accumulated behind the leading edge to watchers, as one
  /// change. An empty buffer means the burst was a single beacon, already out.
  void _publishPending() {
    _publish = null;
    if (_pending.isEmpty) return;
    state = {...state, ..._pending};
    _pending.clear();
    _ensureSweeping();
  }

  /// Presence for [canonicalId] while it's still fresh, else null so the caller
  /// falls back to mesh evidence (a live session, or the last announcement).
  /// Reads through the pending buffer, so an answer is never a hundred
  /// milliseconds behind the beacon that decided it. Only the *notification*
  /// is coalesced; the value is exact the moment it arrives.
  PeerPresence? freshFor(String canonicalId) {
    final p = _pending[canonicalId] ?? state[canonicalId];
    if (p == null || !p.isFresh) return null;
    return p;
  }

  void clear() {
    _sweep?.cancel();
    _sweep = null;
    // Emergency Wipe must not be undone a tenth of a second later by a beacon
    // that was already in the buffer when it ran.
    _publish?.cancel();
    _publish = null;
    _pending.clear();
    state = const <String, PeerPresence>{};
  }
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
/// Independent of our own last-seen switch, which used to force a flat "no"
/// here. It had to: with the switch off the beacon was dropped on arrival, so
/// this fell through to the mesh fallback, and `lastSeen` is refreshed by every
/// announcement — over a relay those never stop, so the guess was permanently
/// "online" and every contact stuck there. The beacon is kept now, so the
/// evidence is real again and the switch is free to mean what it says: it hides
/// *times*, not who is in the app.
bool peerIsOnline({
  required bool hasLiveSession,
  required PeerPresence? beacon,
  required DateTime? lastSeen,
  DateTime? now,
}) {
  // Only a beacon answers this, and only while it is fresh.
  //
  // The two other kinds of evidence used to count and both were wrong about
  // the question. A live Noise session was called definite because it "can
  // only exist while both ends are running" — but on Android the app runs in
  // the background behind a foreground service, so the session outlives
  // anybody looking at it. And a recent announcement was called evidence too,
  // when what it actually says is that a radio is in range.
  //
  // Being reachable is not being in the app, and reading one as the other is
  // what showed somebody as present with the app closed, right up until the
  // process itself was killed. Which road their messages take is a separate
  // fact and has its own indicator; it does not belong in this answer.
  //
  // The cost is honest and worth naming: with no relay and no beacon — two
  // phones on Bluetooth alone — nobody reads as present, because nothing on
  // that path carries the claim. The heartbeat stays relay-only on purpose
  // (see `announcePresence`), so silence there means "not known to be in the
  // app", which is exactly what is shown.
  final at = now ?? DateTime.now();
  if (beacon == null) return false;
  if (at.difference(beacon.at) >= PeerPresence.ttl) return false;
  return beacon.online;
}
