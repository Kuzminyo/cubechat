import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../../core/transport/shared_location.dart';
import '../../chat/data/messages_controller.dart';
import '../../chat/models/message.dart';

/// A contact's latest position that they explicitly sent in the conversation.
@immutable
class SharedMapLocation {
  const SharedMapLocation({
    required this.chatId,
    required this.location,
    required this.sentAt,
    this.live = false,
  });

  final String chatId;
  final SharedLocation location;
  final DateTime sentAt;

  /// True when this came from the map heartbeat rather than from a position
  /// somebody posted into a conversation.
  ///
  /// The difference is what the pin *means* once its stated expiry passes. A
  /// position shared into a chat for fifteen minutes is a promise with an end;
  /// a heartbeat is simply the last place a friend was seen, and their phone
  /// going quiet — closing the app, losing signal, going to sleep — is exactly
  /// the moment you still want to see where they were. So a live pin outlives
  /// its own two-minute window and is only removed when its owner retracts it.
  final bool live;

  /// The position has passed the moment its sender said it stops being current.
  /// Still worth drawing when [live]; worth drawing quietly.
  bool get stale => location.expired;
}

/// Where map friends are, as told by the 45-second beacon.
///
/// Deliberately not chat history. A beacon is transport: it arrives every 45
/// seconds per friend for as long as their map is open, and filing that in the
/// conversation meant a bubble the user had to scroll past every 45 seconds, a
/// history that grew without anybody saying anything, and — because each one
/// counted as an unread inbound message — a read receipt owed for every single
/// one, which is what drowned the relay. So beacons live here instead: one
/// entry per peer, kept on disk.
///
/// **Kept, not expired.** This used to hold the entries in memory and drop each
/// one the moment its two-minute window lapsed, which meant a friend vanished
/// off the map two minutes after closing the app and again on every restart —
/// the map was empty until somebody happened to be looking at theirs at the
/// same moment. A pin now stands as the last known position until one of two
/// things happens: its owner retracts it, or nobody has heard from them in
/// [_forgetAfter].
///
/// Only a beacon that *says* it is a withdrawal removes the entry — see
/// [SharedLocation.retraction]. Merely being expired on arrival is not enough
/// and never was a safe signal: the relay replays its backlog on every
/// reconnect, so opening the app after a night away delivered a pile of
/// long-dead heartbeats, each of which read as "remove this person" and emptied
/// the map of exactly the friends who had been there.
class MapPresenceStore extends Notifier<Map<String, SharedMapLocation>> {
  static const _key = 'map.presence';

  /// How long a silent friend stays on the map. Long enough that a phone off
  /// overnight is still where you left it in the morning, short enough that the
  /// map is not a museum of people you stopped talking to.
  static const _forgetAfter = Duration(days: 3);

  /// How recently a withdrawal must have been minted to still be obeyed.
  ///
  /// Generous enough to survive a slow mesh hop and two phones that disagree
  /// about the time by a couple of minutes, short enough that a backlog the
  /// relay hands over on reconnect cannot empty the map.
  static const _retractionWindow = Duration(minutes: 5);

  Box<dynamic>? _box;

  @override
  Map<String, SharedMapLocation> build() {
    unawaited(_load());
    return const {};
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final raw = box.get(_key);
      if (raw is! List) return;
      final cutoff = DateTime.now().subtract(_forgetAfter);
      final loaded = <String, SharedMapLocation>{};
      for (final row in raw) {
        final entry = _decodeRow(row);
        if (entry == null || entry.sentAt.isBefore(cutoff)) continue;
        loaded[entry.chatId] = entry;
      }
      if (loaded.isEmpty) return;
      // Anything that arrived while the box was opening wins: it is newer by
      // construction.
      state = {...loaded, ...state};
    } catch (e) {
      debugPrint('MapPresenceStore load failed: $e');
    }
  }

  void record(String chatId, SharedLocation location, {DateTime? sentAt}) {
    if (chatId.isEmpty || chatId.startsWith('#')) return;
    final now = DateTime.now();
    final at = _positionHeldAt(location, sentAt ?? now);

    if (location.retraction) {
      // A withdrawal is worth acting on only while it is fresh. Replayed out of
      // the relay's backlog it is a statement about a moment that has already
      // passed, and honouring it would take down a pin that has been standing
      // ever since.
      if (at.isAfter(now.subtract(_retractionWindow))) forget(chatId);
      return;
    }
    if (at.isBefore(now.subtract(_forgetAfter))) return;

    // Beacons do not arrive in the order they were sent: the relay replays its
    // backlog whenever the socket comes back, so a heartbeat from an hour ago
    // can land after the one from a minute ago. The newer position wins,
    // whenever it turns up.
    final known = state[chatId];
    if (known != null && !at.isAfter(known.sentAt)) return;

    state = {
      ...state,
      chatId: SharedMapLocation(
        chatId: chatId,
        location: location,
        sentAt: at,
        live: true,
      ),
    };
    unawaited(_persist());
  }

  /// When this position was actually true, as opposed to when it reached us.
  ///
  /// The two are the same thing for a beacon in flight, and nothing alike for
  /// one the relay kept: dating a replayed heartbeat by its arrival would put
  /// yesterday's position on the map labelled "updated now", and would let it
  /// outrank the one that is current. A beacon's window closes two minutes
  /// after it is minted, so its own expiry is the honest upper bound.
  static DateTime _positionHeldAt(SharedLocation location, DateTime arrivedAt) {
    final expiry = location.expiresAt;
    if (expiry == null || !arrivedAt.isAfter(expiry)) return arrivedAt;
    return expiry;
  }

  void forget(String chatId) {
    if (!state.containsKey(chatId)) return;
    state = {...state}..remove(chatId);
    unawaited(_persist());
  }

  void clear() {
    if (state.isNotEmpty) state = const {};
    unawaited(_clearBox());
  }

  Future<void> _persist() async {
    final box = _box;
    if (box == null) return;
    try {
      await box.put(_key, [for (final e in state.values) _encodeRow(e)]);
    } catch (e) {
      debugPrint('MapPresenceStore persist failed: $e');
    }
  }

  Future<void> _clearBox() async {
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('MapPresenceStore clear failed: $e');
    }
  }

  /// `<chatId>|<encoded position>|<when it reached us>`.
  ///
  /// The position keeps the sender's own encoding, so whatever a future beacon
  /// learns to carry survives a round trip through disk without this file
  /// having to know about it. The pipe is safe as a separator: the id is hex
  /// and the encoding is a base64url URI, and neither can contain one.
  static String _encodeRow(SharedMapLocation entry) =>
      '${entry.chatId}|${entry.location.encode()}|'
      '${entry.sentAt.toUtc().toIso8601String()}';

  static SharedMapLocation? _decodeRow(Object? row) {
    if (row is! String) return null;
    final parts = row.split('|');
    if (parts.length != 3) return null;
    final location = SharedLocation.tryParse(parts[1]);
    final sentAt = DateTime.tryParse(parts[2]);
    if (location == null || sentAt == null || parts[0].isEmpty) return null;
    return SharedMapLocation(
      chatId: parts[0],
      location: location,
      sentAt: sentAt.toLocal(),
      live: true,
    );
  }
}

final mapPresenceStoreProvider =
    NotifierProvider<MapPresenceStore, Map<String, SharedMapLocation>>(
  MapPresenceStore.new,
);

/// Current map pins: live beacons first, then anything a person deliberately
/// shared in a conversation.
///
/// This provider performs no network work and never requests another person's
/// location. A contact appears only after sending a location themselves, and an
/// expired live-location disappears automatically. A live beacon wins over a
/// hand-shared pin because it is, by construction, the newer of the two.
final sharedMapLocationsProvider =
    Provider<Map<String, SharedMapLocation>>((ref) {
  final history = ref.watch(messagesControllerProvider);
  final beacons = ref.watch(mapPresenceStoreProvider);
  final shared = sharedMapLocationsFromHistory(history);
  if (beacons.isEmpty) return shared;
  return {...shared, ...beacons};
});
@visibleForTesting
Map<String, SharedMapLocation> sharedMapLocationsFromHistory(
  Map<String, List<Message>> history, {
  DateTime? now,
}) {
  final result = <String, SharedMapLocation>{};
  final currentTime = now ?? DateTime.now();

  for (final entry in history.entries) {
    // Channels mix several authors into one bucket, so the chat id cannot be
    // attributed to one avatar. The first map iteration is intentionally 1:1.
    if (entry.key.startsWith('#')) continue;

    for (final message in entry.value.reversed) {
      if (message.isMine || message.kind != MessageKind.text) continue;
      final location = SharedLocation.tryParse(message.text);
      if (location == null) continue;
      // The newest location message decides. Falling back to an older pin after
      // a newer live share expires would silently move the person backwards.
      if (location.expiresAt == null ||
          !currentTime.isAfter(location.expiresAt!)) {
        result[entry.key] = SharedMapLocation(
          chatId: entry.key,
          location: location,
          sentAt: message.sentAt,
        );
      }
      break;
    }
  }

  return result;
}
