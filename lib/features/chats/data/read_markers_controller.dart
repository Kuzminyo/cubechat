import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';

/// When the user last *read* each chat, keyed by the same id the chat list uses
/// (a peer's pubkey-hex, or a `#channel` name).
///
/// This is what makes the unread badge correct: before this existed the chat
/// list counted *every* inbound message forever, so a badge never cleared and
/// the "unread" state was meaningless. Now a chat's unread count is the inbound
/// messages whose `sentAt` is after its marker; opening a chat advances the
/// marker to now.
///
/// A purely local preference, so it lives in the shared settings box next to
/// favourites / background-mode rather than travelling with a peer's identity.
class ReadMarkersController extends Notifier<Map<String, DateTime>> {
  static const _key = 'read_markers';

  Box<dynamic>? _box;

  Future<void>? _loading;

  @override
  Map<String, DateTime> build() {
    _loading = _load();
    return const <String, DateTime>{};
  }

  /// Resolves once the box is open, whether or not it had anything in it.
  ///
  /// The same guarantee [AckMarkersController.loaded] gives, and needed for the
  /// same reason from the other side. Both of these are read together when read
  /// receipts are swept — one says how far the person has read, the other how
  /// far that has been reported — and the sweep runs when a relay connects,
  /// about a second after launch, while these boxes are still opening.
  ///
  /// Read too early they disagree in the worst possible direction: this one
  /// loaded and the other not, which reads as "everything has been read and
  /// nothing has been acknowledged" and acknowledges the entire conversation
  /// again. On a phone with a couple of hundred messages that is sixteen relay
  /// publishes and two seconds of work on every cold start, and a 200-line
  /// debug log that holds three seconds of history because the storm filled it.
  Future<void> get loaded => _loading ?? Future<void>.value();

  Future<void> _load() async {
    try {
      final box =
          await hiveCipherProvider.openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final raw = box.get(_key);
      if (raw is Map) {
        final loaded = <String, DateTime>{};
        raw.forEach((dynamic k, dynamic v) {
          if (k is String && v is String) {
            final dt = DateTime.tryParse(v);
            if (dt != null) loaded[k] = dt;
          }
        });
        // Merge under any markers set while the box was still loading.
        if (loaded.isNotEmpty) state = {...loaded, ...state};
      }
    } catch (e) {
      debugPrint('ReadMarkersController load failed: $e');
    }
  }

  DateTime? lastReadAt(String chatId) => state[chatId];

  /// Mark [chatId] read as of [at] (default: now). Never moves a marker
  /// backwards, so a stale re-open or an out-of-order call can't resurrect
  /// already-read messages as unread.
  Future<void> markRead(String chatId, {DateTime? at}) async {
    final when = at ?? DateTime.now();
    final existing = state[chatId];
    if (existing != null && !when.isAfter(existing)) return;
    state = {...state, chatId: when};
    await _persist();
  }

  /// Drop a marker — used when the chat itself is deleted.
  Future<void> forget(String chatId) async {
    if (!state.containsKey(chatId)) return;
    state = {...state}..remove(chatId);
    await _persist();
  }

  /// Used by Emergency Wipe.
  Future<void> clear() async {
    state = const <String, DateTime>{};
    try {
      await _box?.delete(_key);
    } catch (e) {
      debugPrint('ReadMarkersController clear failed: $e');
    }
  }

  Future<void> _persist() async {
    try {
      // See [loaded]. Without this the first write of a launch lands on a null
      // box and is lost without a word — and the write that happens first on a
      // launch is this one, because marking a chat read is what opening it
      // does. So a chat opened in the seconds after launch was read on screen
      // and unread again on the next start, and the receipt sweep saw no marker
      // at all for it.
      //
      // [AckMarkersController] below has carried this line for a while; this
      // half of the same file never got it. The two are read together and one
      // of them was silently dropping writes.
      await loaded;
      await _box?.put(_key, {
        for (final e in state.entries) e.key: e.value.toIso8601String(),
      });
    } catch (e) {
      debugPrint('ReadMarkersController persist failed: $e');
    }
  }
}

final readMarkersControllerProvider =
    NotifierProvider<ReadMarkersController, Map<String, DateTime>>(
  ReadMarkersController.new,
);

/// How far each chat's read receipts have actually been *sent*, which is not
/// the same question as how far it has been read.
///
/// [ReadMarkersController] is local: it decides the unread badge. This one is
/// about what the other phone has been told, and it exists because the set that
/// used to answer it lived only in memory. Its own comment said so — "a restart
/// may re-send one receipt per message" — and what that reads like on a phone
/// is every chat re-acknowledging its entire history at once on launch.
///
/// Measured, not supposed. A log taken right after a fresh install showed one
/// conversation sending 144 acknowledgements in twelve relay frames inside a
/// second and a half, with the same happening for every other chat and every
/// channel receipt fanning out to seven peers on top. The frames that landed in
/// the middle of it cost 34-37 ms of build each, with the chat list rebuilding
/// twenty-two times a second because every one of those publishes moved a
/// provider it watches. That is the freeze on cold start and the stall the
/// first time a chat is opened, and both stop happening the second time round
/// for the same reason: by then the in-memory set is full.
///
/// A timestamp per chat rather than a set of ids, because the set grows with
/// every message ever read and this does not.
///
/// **The trade this made has now been paid, so it is a watermark *and* a
/// bounded set.** What was written here was: "a message that arrives late with
/// a timestamp older than the marker will not have its receipt re-sent after a
/// restart, so its sender may keep one tick" — accepted on the grounds that a
/// late arrival is unusual. It is not. Since 956 a message carries the
/// *sender's* clock, so anything that waited on a relay arrives stamped older
/// than it landed, and a batch of media is delivered exactly that way.
///
/// Reported as "не просматривается смс хотя просмотрели", and both logs agree:
/// four stickers sent at 21:12:03 reached the other phone at 21:14:35, after
/// two restarts; the chat was opened, four banners were cleared, and **one**
/// acknowledgement went out. The other three were below the watermark, which
/// means not merely unsent — unsendable, for good.
///
/// So [ackedIds] answers exactly for everything it still holds, and the
/// watermark answers for what has fallen out of it. That keeps the cold-start
/// storm fixed — the set is capped, so history beyond it is still cut off by a
/// single comparison — while making the case that actually happens correct.
/// [_maxAckedIds] entries is about 40 KB.
class AckMarkersController extends Notifier<Map<String, DateTime>> {
  static const _key = 'ack_markers';
  static const _idsKey = 'ack_marker_ids';

  /// How many acknowledged wire ids are remembered across restarts.
  ///
  /// Large enough that "arrived late" is always inside it in practice — a
  /// backlog is tens of messages, not hundreds — and small enough to stay a
  /// rounding error on disk. Beyond it the watermark takes over, which is the
  /// behaviour this whole class was introduced to get.
  static const int _maxAckedIds = 500;

  /// Wire id to the message's own timestamp, oldest evicted first.
  ///
  /// The timestamps are not decoration: [ackCoverFrom] is the oldest of them,
  /// and that is what says how far back this set can be trusted to answer.
  final Map<String, DateTime> _ackedIds = {};

  Box<dynamic>? _box;
  Future<void>? _loading;

  @override
  Map<String, DateTime> build() {
    _loading = _load();
    return const <String, DateTime>{};
  }

  /// Resolves once the box is open, whether or not it had anything in it.
  ///
  /// Held rather than fired and forgotten because [_persist] has to wait on it.
  /// A marker set before the box opened used to write to `_box?.put` on a null
  /// and vanish without a word — and the call that sets it happens on chat
  /// open, which is exactly the moment a launch is still opening boxes. The
  /// fix that stops the cold-start storm would have quietly failed on the one
  /// launch it was written for.
  Future<void> get loaded => _loading ?? Future<void>.value();

  Future<void> _load() async {
    try {
      final box =
          await hiveCipherProvider.openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final raw = box.get(_key);
      if (raw is Map) {
        final loaded = <String, DateTime>{};
        raw.forEach((dynamic k, dynamic v) {
          if (k is String && v is String) {
            final dt = DateTime.tryParse(v);
            if (dt != null) loaded[k] = dt;
          }
        });
        // Merged under anything set while the box was still opening, the same
        // way the read markers are — receipts go out on chat open, which can
        // easily beat a disk read.
        if (loaded.isNotEmpty) state = {...loaded, ...state};
      }
      final ids = box.get(_idsKey);
      if (ids is Map) {
        final restored = <String, DateTime>{};
        ids.forEach((dynamic k, dynamic v) {
          if (k is String && v is String) {
            final dt = DateTime.tryParse(v);
            if (dt != null) restored[k] = dt;
          }
        });
        // Under, not over: an id acknowledged while the box was opening is
        // newer than anything on disk and must not be dropped.
        for (final e in restored.entries) {
          _ackedIds.putIfAbsent(e.key, () => e.value);
        }
        _evictAckedIds();
      }
    } catch (e) {
      debugPrint('AckMarkersController load failed: $e');
    }
  }

  DateTime? ackedUpTo(String chatId) => state[chatId];

  /// Whether this exact message has already been acknowledged.
  bool hasAcked(String wireId) => _ackedIds.containsKey(wireId);

  /// How far back [hasAcked] can be trusted to answer.
  ///
  /// Null while the set is under its cap — nothing has been forgotten, so it
  /// answers for everything. Once full it is the oldest timestamp still held,
  /// and anything at or before that has to fall back on the watermark.
  DateTime? get ackCoverFrom {
    if (_ackedIds.length < _maxAckedIds) return null;
    DateTime? oldest;
    for (final at in _ackedIds.values) {
      if (oldest == null || at.isBefore(oldest)) oldest = at;
    }
    return oldest;
  }

  /// Record ids whose receipt actually reached somebody.
  Future<void> markIdsAcked(Map<String, DateTime> ids) async {
    if (ids.isEmpty) return;
    var added = false;
    for (final e in ids.entries) {
      if (_ackedIds.containsKey(e.key)) continue;
      _ackedIds[e.key] = e.value;
      added = true;
    }
    if (!added) return;
    _evictAckedIds();
    await _persist();
  }

  /// Drop the oldest until the set is back inside its cap.
  void _evictAckedIds() {
    if (_ackedIds.length <= _maxAckedIds) return;
    final byAge = _ackedIds.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    for (var i = 0; i < byAge.length - _maxAckedIds; i++) {
      _ackedIds.remove(byAge[i].key);
    }
  }

  /// Never moves backwards, for the same reason the read marker does not: a
  /// slice that went out cannot un-go.
  Future<void> markAcked(String chatId, DateTime at) async {
    final existing = state[chatId];
    if (existing != null && !at.isAfter(existing)) return;
    state = {...state, chatId: at};
    await _persist();
  }

  Future<void> forget(String chatId) async {
    if (!state.containsKey(chatId)) return;
    state = {...state}..remove(chatId);
    await _persist();
  }

  /// Used by Emergency Wipe.
  Future<void> clear() async {
    state = const <String, DateTime>{};
    _ackedIds.clear();
    try {
      await _box?.delete(_key);
      await _box?.delete(_idsKey);
    } catch (e) {
      debugPrint('AckMarkersController clear failed: $e');
    }
  }

  Future<void> _persist() async {
    try {
      // See [loaded]: without this the first write of a launch lands on a null
      // box and is lost.
      await loaded;
      await _box?.put(_key, {
        for (final e in state.entries) e.key: e.value.toIso8601String(),
      });
      await _box?.put(_idsKey, {
        for (final e in _ackedIds.entries) e.key: e.value.toIso8601String(),
      });
    } catch (e) {
      debugPrint('AckMarkersController persist failed: $e');
    }
  }
}

final ackMarkersControllerProvider =
    NotifierProvider<AckMarkersController, Map<String, DateTime>>(
  AckMarkersController.new,
);
