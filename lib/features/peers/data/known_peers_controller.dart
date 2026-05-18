import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_init.dart';
import '../models/known_peer.dart';

/// Roster of peers we have authenticated through Noise XX.
///
/// Backed by Hive (M4) — the roster survives app restarts. Each peer is
/// stored as a plain `Map<String, dynamic>` so we don't need code-gen for
/// a TypeAdapter (the schema is two strings + an ISO timestamp).
class KnownPeersController extends Notifier<Map<String, KnownPeer>> {
  Box<Map<dynamic, dynamic>>? _box;

  @override
  Map<String, KnownPeer> build() {
    // Kick off the async load; UI updates as soon as the box is ready.
    unawaited(_loadFromDisk());
    return <String, KnownPeer>{};
  }

  Future<void> _loadFromDisk() async {
    try {
      final box = await Hive.openBox<Map<dynamic, dynamic>>(HiveBoxes.knownPeers);
      _box = box;
      final loaded = <String, KnownPeer>{};
      for (final key in box.keys) {
        final raw = box.get(key);
        if (raw == null) continue;
        try {
          loaded[key as String] = _decode(raw);
        } catch (e) {
          debugPrint('skip corrupt known peer "$key": $e');
        }
      }
      if (loaded.isNotEmpty) {
        // Merge with any in-memory upserts that happened before we finished
        // loading (race: the first handshake may complete while disk is
        // still being read).
        state = {...loaded, ...state};
      }
    } catch (e, st) {
      debugPrint('KnownPeers load failed: $e\n$st');
    }
  }

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
    } else if (newIsPlaceholder &&
        existing.displayName.isNotEmpty &&
        !existing.displayName.startsWith('Peer ')) {
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
      // Preserve a prior verification across name / lastSeen refreshes —
      // verification is tied to the pubkey, which by definition hasn't
      // changed if we're upserting under the same pubkeyHex.
      verifiedAt: existing?.verifiedAt,
    );
    state = {...state, pubkeyHex: entry};
    _persist(entry);
  }

  /// Stamp a peer as verified (the user compared fingerprints out-of-band).
  /// No-op if the peer isn't in the roster yet.
  Future<void> markVerified(String pubkeyHex) async {
    final existing = state[pubkeyHex];
    if (existing == null) return;
    final updated = existing.copyWith(verifiedAt: DateTime.now());
    state = {...state, pubkeyHex: updated};
    await _persist(updated);
  }

  /// Revoke a previously-granted verification (the user changed their mind
  /// or suspects a MITM compromise).
  Future<void> revokeVerification(String pubkeyHex) async {
    final existing = state[pubkeyHex];
    if (existing == null || !existing.isVerified) return;
    final updated = existing.copyWith(clearVerifiedAt: true);
    state = {...state, pubkeyHex: updated};
    await _persist(updated);
  }

  /// Forget every known peer — used by the Emergency Wipe flow.
  Future<void> clear() async {
    state = <String, KnownPeer>{};
    try {
      await _box?.clear();
    } catch (e) {
      debugPrint('KnownPeers box clear failed: $e');
    }
  }

  /// Drop a single peer.
  Future<void> forget(String pubkeyHex) async {
    if (!state.containsKey(pubkeyHex)) return;
    state = {...state}..remove(pubkeyHex);
    try {
      await _box?.delete(pubkeyHex);
    } catch (e) {
      debugPrint('KnownPeers delete($pubkeyHex) failed: $e');
    }
  }

  Future<void> _persist(KnownPeer peer) async {
    final box = _box;
    if (box == null) return; // not yet loaded; will rewrite on next upsert
    try {
      await box.put(peer.pubkeyHex, _encode(peer));
    } catch (e) {
      debugPrint('KnownPeers persist failed: $e');
    }
  }

  static Map<String, dynamic> _encode(KnownPeer p) => {
        'pubkeyHex': p.pubkeyHex,
        'displayName': p.displayName,
        'lastSeenIso': p.lastSeen.toIso8601String(),
        'verifiedAtIso': p.verifiedAt?.toIso8601String(),
      };

  static KnownPeer _decode(Map<dynamic, dynamic> m) {
    final verifiedRaw = m['verifiedAtIso'] as String?;
    return KnownPeer(
      pubkeyHex: m['pubkeyHex'] as String,
      displayName: (m['displayName'] as String?) ?? '',
      lastSeen: DateTime.tryParse((m['lastSeenIso'] as String?) ?? '') ??
          DateTime.now(),
      verifiedAt: verifiedRaw == null ? null : DateTime.tryParse(verifiedRaw),
    );
  }
}

final knownPeersControllerProvider =
    NotifierProvider<KnownPeersController, Map<String, KnownPeer>>(
  KnownPeersController.new,
);
