import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../../../core/util/media_storage.dart';
import '../models/message.dart';

/// Per-peer message store, keyed by the canonical chat id (the peer's
/// pubkeyHex once the handshake has authenticated them).
///
/// Backed by Hive (M4) so chat history survives app restarts. Each entry in
/// the box is a `List<Map<String, dynamic>>` of messages — simple, schema-
/// stable, no codegen TypeAdapter required.
class MessagesController extends Notifier<Map<String, List<Message>>> {
  Box<List<dynamic>>? _box;
  Future<void>? _loading;

  /// Completes once the persisted history has been merged into [state]. The app
  /// doesn't need to wait (the UI rebuilds when it lands); tests do.
  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  Map<String, List<Message>> build() {
    // A debounced write must not outlive the notifier that queued it: the box
    // is closed with the container, so a timer firing afterwards has nowhere to
    // put anything and only logs a failure for a write nobody is waiting on.
    ref.onDispose(() {
      _persistTimer?.cancel();
      _persistTimer = null;
    });
    unawaited(_loading = _loadFromDisk());
    return <String, List<Message>>{};
  }

  Future<void> _loadFromDisk() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<List<dynamic>>(HiveBoxes.messages);
      _box = box;
      final loaded = <String, List<Message>>{};
      final repaired = <String>[];
      for (final key in box.keys) {
        final raw = box.get(key);
        if (raw == null) continue;
        try {
          final decoded = raw
              .map((dynamic m) => _decode((m as Map).cast<String, dynamic>()))
              .toList();
          // Heal history written before [append] deduped: a device that took a
          // relay backlog replay on every launch has each internet-delivered
          // message stored several times over.
          final unique = _withoutWireIdDuplicates(decoded);
          if (unique.length != decoded.length) repaired.add(key as String);
          loaded[key as String] = unique;
        } catch (e) {
          debugPrint('skip corrupt messages bucket "$key": $e');
        }
      }
      if (loaded.isNotEmpty) {
        state = {...loaded, ...state};
      }
      for (final key in repaired) {
        debugPrint('messages bucket "$key": dropped duplicate wireIds');
        _persist(key, loaded[key]!);
      }
    } catch (e, st) {
      debugPrint('Messages load failed: $e\n$st');
    }
  }

  List<Message> forPeer(String peerId) => state[peerId] ?? const <Message>[];

  /// Appends [msg] unless this chat already holds a message with the same
  /// transport [Message.wireId]. Returns whether it was actually added, so a
  /// caller can skip the notification/fan-out that goes with a *new* message.
  ///
  /// This idempotency is what makes a redelivered frame harmless. A message can
  /// legitimately reach us twice: a Nostr relay replays its stored backlog to
  /// every fresh subscription, a mesh peer hands over frames it was holding for
  /// us, and the same message can arrive over two paths at once. The in-memory
  /// dedup cache catches that only inside its TTL and only within one process —
  /// after a restart it is empty, which is exactly when the relay backlog is
  /// re-downloaded, and the whole internet-delivered history used to land in the
  /// chat a second time. The wireId (hex of the 16-byte transport msgId, or the
  /// media id for an assembled photo/voice note) is stable across all of those
  /// paths and restarts, so it is the key that has to gate the insert.
  bool append(String peerId, Message msg) {
    final current = state[peerId] ?? const <Message>[];
    final wireId = msg.wireId;
    if (wireId != null && current.any((m) => m.wireId == wireId)) return false;
    final next = [...current, msg];
    state = {...state, peerId: next};
    _persist(peerId, next);
    return true;
  }

  /// Point an existing attachment bubble at a file that has just landed again.
  ///
  /// [append] is idempotent on wireId, which is what stops a relay backlog from
  /// re-inserting the whole history — and also what would stop a re-sent file
  /// from being adopted by the bubble that asked for it. Same id, same message,
  /// new path: this is the update half of that rule.
  bool restoreFilePath(String peerId, String wireId, String path) {
    final current = state[peerId];
    if (current == null) return false;
    final idx = current.indexWhere((m) => m.wireId == wireId);
    if (idx == -1) return false;
    final list = [...current]..[idx] = current[idx].copyWith(filePath: path);
    state = {...state, peerId: list};
    _persist(peerId, list);
    return true;
  }

  /// Burn a view-once photo: delete the file, blank the path, and stamp the
  /// row as opened — but keep the row.
  ///
  /// Keeping it is the point. [append] is idempotent on [Message.wireId], and
  /// a view-once photo's wireId is the hash of its media id, so as long as the
  /// tombstone still occupies that id, a re-delivered manifest (a relay
  /// replaying the transfer, a mesh re-flood) is absorbed into the opened
  /// bubble instead of arriving as a fresh, viewable one. Deleting the row
  /// outright would hand that loophole back.
  ///
  /// Matched by wireId rather than local id: the sender learns a photo was
  /// opened by its media id, which is the only handle both devices share.
  /// Returns the message it burned, so the caller can tell the other side.
  Future<Message?> consumeViewOnce(String peerId, String wireId) async {
    final current = state[peerId];
    if (current == null) return null;
    final idx = current.indexWhere((m) => m.wireId == wireId && m.viewOnce);
    if (idx == -1) return null;
    final target = current[idx];
    if (target.viewOnceConsumed) return null; // already burned; stay idempotent

    final path = target.imagePath;
    if (path != null) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (e) {
        // The row is still marked opened even if the unlink failed — a file we
        // could not remove is a worse outcome than a bubble that lies about it.
        debugPrint('view-once delete failed: $e');
      } finally {
        // Existence answers are memoized for a couple of seconds so the bubbles
        // are not stat()-ing on every animation frame. A burn is exactly the
        // case that must not wait out that window: the promise is that the
        // photo is gone the moment the viewer closes.
        MediaPaths.forget(path);
      }
    }
    final list = [...current]..[idx] = target.copyWith(
        clearImagePath: true,
        viewOnceConsumedAt: DateTime.now(),
      );
    state = {...state, peerId: list};
    _persist(peerId, list);
    return target;
  }

  void updateStatus(String peerId, String msgId, MessageStatus status) {
    final current = state[peerId];
    if (current == null) return;
    final idx = current.indexWhere((m) => m.id == msgId);
    if (idx == -1) return;
    final list = [...current]..[idx] = current[idx].copyWith(status: status);
    state = {...state, peerId: list};
    _persist(peerId, list);
  }

  void updateRoute(
    String peerId,
    String msgId,
    MessageRoute route, {
    int? hops,
  }) {
    final current = state[peerId];
    if (current == null) return;
    final idx = current.indexWhere((m) => m.id == msgId);
    if (idx == -1) return;
    final list = [...current]..[idx] =
        current[idx].copyWith(route: route, routeHops: hops);
    state = {...state, peerId: list};
    _persist(peerId, list);
  }

  /// Flip our own outgoing messages to [MessageStatus.read] when the peer's
  /// read receipt lands, stamping [Message.readAt] with the moment it did.
  /// Messages are matched by their transport [wireId] (the id both sides share);
  /// non-mine messages and already-read ones are left untouched. No-op when
  /// nothing matched (idempotent under resends — the first receipt's timestamp
  /// is the one that sticks).
  /// Returns how many of our messages the receipt actually moved, so the
  /// caller can say whether a receipt that arrived did anything. Zero is the
  /// interesting number: it means the ids in it matched nothing in this chat.
  int markRead(String peerId, Set<String> wireIds) {
    final current = state[peerId];
    if (current == null || wireIds.isEmpty) return 0;
    var changed = 0;
    final now = DateTime.now();
    final list = [...current];
    for (var i = 0; i < list.length; i++) {
      final m = list[i];
      if (m.isMine &&
          m.wireId != null &&
          m.status != MessageStatus.read &&
          wireIds.contains(m.wireId)) {
        list[i] = m.copyWith(status: MessageStatus.read, readAt: now);
        changed++;
      }
    }
    if (changed == 0) return 0;
    state = {...state, peerId: list};
    _persist(peerId, list);
    return changed;
  }

  /// Remove one message from a chat by its local [messageId] — the "delete for
  /// me" path. Works on any message (ours or theirs, any kind), since it never
  /// leaves this device.
  void deleteLocal(String peerId, String messageId) {
    final current = state[peerId];
    if (current == null) return;
    final next = current.where((m) => m.id != messageId).toList();
    if (next.length == current.length) return;
    state = {...state, peerId: next};
    _persist(peerId, next);
  }

  /// The same, for a whole selection.
  ///
  /// One state write and one persist for the batch rather than N of each —
  /// deleting thirty messages one at a time rewrites the chat's Hive entry
  /// thirty times, and the list rebuilds on every one of them.
  void deleteManyLocal(String peerId, Set<String> messageIds) {
    if (messageIds.isEmpty) return;
    final current = state[peerId];
    if (current == null) return;
    final next = current.where((m) => !messageIds.contains(m.id)).toList();
    if (next.length == current.length) return;
    state = {...state, peerId: next};
    _persist(peerId, next);
  }

  /// Remove one of *our own* messages by its transport [wireId] — the local
  /// half of "delete for everyone". Returns whether anything was removed.
  bool deleteMineByWireId(String peerId, String wireId) =>
      _deleteByWireId(peerId, wireId, mine: true, authorId: null);

  /// Apply an inbound "delete for everyone": drop the peer's message with this
  /// [wireId]. The author guard mirrors [editFromPeer] — a channel message may
  /// only be retracted by its author.
  bool deleteFromPeer(String peerId, String wireId, {String? authorId}) =>
      _deleteByWireId(peerId, wireId, mine: false, authorId: authorId);

  bool _deleteByWireId(
    String peerId,
    String wireId, {
    required bool mine,
    required String? authorId,
  }) {
    final current = state[peerId];
    if (current == null) return false;
    final idx = current.indexWhere((m) =>
        m.wireId == wireId &&
        m.isMine == mine &&
        (authorId == null || m.authorId == authorId));
    if (idx == -1) return false;
    final next = [...current]..removeAt(idx);
    state = {...state, peerId: next};
    _persist(peerId, next);
    return true;
  }

  /// Rewrite the text of one of *our own* messages. Returns false when the
  /// target isn't there, isn't ours, isn't text, or the text is unchanged —
  /// callers use that to decide whether anything needs to go on the wire.
  bool editMine(String peerId, String targetWireId, String text) =>
      _applyEdit(peerId, targetWireId, text, mine: true, authorId: null);

  /// Apply an inbound edit. The author check is the whole point: [authorId] is
  /// the sender's signing-key fingerprint for channel messages, and for a 1:1
  /// chat "not mine" already pins the sender. Without it any peer on the mesh
  /// could rewrite words we put on screen.
  bool editFromPeer(
    String peerId,
    String targetWireId,
    String text, {
    String? authorId,
  }) =>
      _applyEdit(peerId, targetWireId, text, mine: false, authorId: authorId);

  bool _applyEdit(
    String peerId,
    String targetWireId,
    String text, {
    required bool mine,
    required String? authorId,
  }) {
    final current = state[peerId];
    if (current == null || text.isEmpty) return false;
    final idx = current.indexWhere((m) => m.wireId == targetWireId);
    if (idx == -1) return false;
    final m = current[idx];
    if (m.isMine != mine) return false;
    if (m.kind != MessageKind.text) return false;
    // Channel messages carry their author; an edit must come from them.
    if (authorId != null && m.authorId != authorId) return false;
    if (m.text == text) return false;

    final list = [...current]..[idx] =
        m.copyWith(text: text, editedAt: DateTime.now());
    state = {...state, peerId: list};
    _persist(peerId, list);
    return true;
  }

  /// Attach or remove an emoji reaction on the message whose transport
  /// [targetWireId] matches. [reactorId] is `'me'` locally or a short sender
  /// fingerprint remotely, so a reactor can toggle their own reaction and the
  /// per-emoji count stays correct. No-op when the target isn't found or the
  /// mutation wouldn't change anything (idempotent under mesh resends).
  void applyReaction(
    String peerId, {
    required String targetWireId,
    required String emoji,
    required String reactorId,
    required bool add,
  }) {
    final current = state[peerId];
    if (current == null) return;
    final idx = current.indexWhere((m) => m.wireId == targetWireId);
    if (idx == -1) return;
    final m = current[idx];
    // Deep-copy so we never mutate the (possibly const/shared) existing map.
    final next = <String, Set<String>>{
      for (final e in m.reactions.entries) e.key: {...e.value},
    };
    final reactors = next.putIfAbsent(emoji, () => <String>{});
    if (add) {
      if (!reactors.add(reactorId)) return; // already present
    } else {
      if (!reactors.remove(reactorId)) return; // wasn't there
    }
    if (reactors.isEmpty) next.remove(emoji);
    final list = [...current]..[idx] = m.copyWith(reactions: next);
    state = {...state, peerId: list};
    _persist(peerId, list);
  }

  /// Record that [readerId] has seen every message in [wireIds], in a channel.
  ///
  /// The 1:1 equivalent is [markRead], which flips a single status because a
  /// 1:1 chat has exactly one possible reader. A channel has as many as hold
  /// the key, so this accumulates them instead — the same additive, per-actor,
  /// idempotent shape as [applyReaction], and for the same reason: mesh and
  /// relay both resend, so applying an acknowledgement twice has to be free.
  ///
  /// **First write wins on the timestamp.** A repeat receipt means the frame
  /// was resent, not that they read it again, and letting the later copy
  /// overwrite would drift every reader's time forward on every duplicate.
  void applyChannelRead(
    String chatId, {
    required String readerId,
    required String readerName,
    required Set<String> wireIds,
    required DateTime at,
  }) {
    final current = state[chatId];
    if (current == null || wireIds.isEmpty) return;

    var changed = false;
    final list = [...current];
    for (var i = 0; i < list.length; i++) {
      final m = list[i];
      final id = m.wireId;
      if (id == null || !wireIds.contains(id)) continue;
      if (m.readBy.containsKey(readerId)) continue; // already recorded
      // Bounded so a peer that keeps inventing signing keys cannot grow one
      // message without limit. Far above any channel a phone can hold.
      if (m.readBy.length >= maxReadersPerMessage) continue;
      list[i] = m.copyWith(
        readBy: <String, ChannelRead>{
          ...m.readBy,
          readerId: ChannelRead(name: readerName, at: at),
        },
      );
      changed = true;
    }
    if (!changed) return;
    state = {...state, chatId: list};
    _persist(chatId, list);
  }

  /// Ceiling on [Message.readBy] entries for one message.
  /// Applies a signed channel-poll vote. A later vote by the same participant
  /// replaces their earlier choice, making retries and route duplicates safe.
  void applyPollVote(
    String chatId, {
    required String pollWireId,
    required String voterId,
    required int option,
  }) {
    final current = state[chatId];
    if (current == null) return;
    final index = current.indexWhere((message) =>
        message.wireId == pollWireId && message.kind == MessageKind.poll);
    if (index == -1) return;
    final message = current[index];
    if (option < 0 || option >= message.pollOptions.length) return;
    if (message.pollVotes[voterId] == option) return;
    final votes = {...message.pollVotes, voterId: option};
    final next = [...current]..[index] = message.copyWith(pollVotes: votes);
    state = {...state, chatId: next};
    _persist(chatId, next);
  }

  static const int maxReadersPerMessage = 64;

  /// Flags an outgoing message as forward-secret once the send path has
  /// confirmed the X3DH cipher was actually used (the placeholder is
  /// appended before the body is built).
  void markForwardSecret(String peerId, String msgId) {
    final current = state[peerId];
    if (current == null) return;
    final idx = current.indexWhere((m) => m.id == msgId);
    if (idx == -1) return;
    if (current[idx].forwardSecret) return;
    final list = [...current]..[idx] =
        current[idx].copyWith(forwardSecret: true);
    state = {...state, peerId: list};
    _persist(peerId, list);
  }

  /// Fills in [imagePath] (and bumps the status) on an existing in-flight
  /// image message once all chunks have been reassembled. The message id
  /// must already exist in the per-peer list — callers should append the
  /// placeholder Message with `imagePath: null` first.
  void completeImage(
    String peerId,
    String msgId, {
    required String imagePath,
    required MessageStatus status,
  }) {
    final current = state[peerId];
    if (current == null) return;
    final idx = current.indexWhere((m) => m.id == msgId);
    if (idx == -1) return;
    final list = [...current]..[idx] =
        current[idx].copyWith(imagePath: imagePath, status: status);
    state = {...state, peerId: list};
    _persist(peerId, list);
  }

  /// Mirror of [completeImage] for voice messages.
  void completeAudio(
    String peerId,
    String msgId, {
    required String audioPath,
    required int durationMs,
    required MessageStatus status,
  }) {
    final current = state[peerId];
    if (current == null) return;
    final idx = current.indexWhere((m) => m.id == msgId);
    if (idx == -1) return;
    final list = [...current]..[idx] = current[idx].copyWith(
        audioPath: audioPath,
        audioDurationMs: durationMs,
        status: status,
      );
    state = {...state, peerId: list};
    _persist(peerId, list);
  }

  /// Erase every conversation — used by Emergency Wipe.
  Future<void> clearAll() async {
    // Before the box is touched, and without flushing: a debounced write still
    // holding a snapshot of a conversation would otherwise land *after* the
    // clear and put it straight back. A wipe that leaves messages behind is the
    // worst bug this file could have.
    _persistTimer?.cancel();
    _persistTimer = null;
    _dirty.clear();
    state = <String, List<Message>>{};
    try {
      await _box?.clear();
    } catch (e) {
      debugPrint('Messages box clear failed: $e');
    }
  }

  /// Remove messages older than [cutoff] from one conversation.
  ///
  /// This is the storage-side primitive used by per-chat auto-delete. It is
  /// intentionally idempotent so the periodic privacy sweep can call it even
  /// when nothing has expired.
  ///
  /// [since] bounds it from below: anything sent before that instant is left
  /// alone however old it is. Auto-delete passes the moment it was switched on,
  /// so the history that was already there when the user turned it on is not
  /// swept away by a setting they understood as "from now on". Null means no
  /// lower bound, which is the old behaviour and what a `/clear`-style caller
  /// wants.
  Future<int> deleteBefore(
    String chatId,
    DateTime cutoff, {
    DateTime? since,
  }) async {
    final current = state[chatId];
    if (current == null || current.isEmpty) return 0;
    final next = current
        .where((message) =>
            !message.sentAt.isBefore(cutoff) ||
            (since != null && message.sentAt.isBefore(since)))
        .toList();
    final removed = current.length - next.length;
    if (removed == 0) return 0;
    if (next.isEmpty) {
      state = {...state}..remove(chatId);
      // Same reasoning as clearAll: drop the pending snapshot rather than let
      // it be written over the delete.
      _dirty.remove(chatId);
      try {
        await _box?.delete(chatId);
      } catch (e) {
        debugPrint('Messages auto-delete($chatId) failed: $e');
      }
    } else {
      state = {...state, chatId: next};
      _persist(chatId, next);
    }
    return removed;
  }

  /// Erase a single chat (the `/clear` IRC command).
  Future<void> clearForChat(String chatId) async {
    if (!state.containsKey(chatId)) return;
    state = {...state}..remove(chatId);
    // A pending snapshot of this chat would land after the delete and undo it.
    _dirty.remove(chatId);
    try {
      await _box?.delete(chatId);
    } catch (e) {
      debugPrint('Messages delete($chatId) failed: $e');
    }
  }

  /// [msgs] with later copies of an already-seen [Message.wireId] removed,
  /// keeping the first (oldest) copy and its accumulated reactions/edits.
  /// Messages without a wireId — anything sent before the transport minted one,
  /// and our own outgoing media — are left alone: there is no key to compare
  /// them on, and two identical photos in a row can be genuine.
  static List<Message> _withoutWireIdDuplicates(List<Message> msgs) {
    final seen = <String>{};
    final out = <Message>[];
    for (final m in msgs) {
      final wireId = m.wireId;
      if (wireId != null && !seen.add(wireId)) continue;
      out.add(m);
    }
    return out;
  }

  /// Conversations with an unwritten change, and the snapshot to write.
  ///
  /// One Hive key holds a whole conversation, so persisting anything means
  /// re-encoding and re-encrypting all of it. That was being done on every
  /// mutation from eighteen call sites — and most of them are not "a message
  /// arrived", they are a tick turning grey to blue, a reaction, a read
  /// receipt. On a chat with two thousand messages a single delivery receipt
  /// re-encoded two thousand messages and pushed the lot through AES, on the UI
  /// isolate. The longer a conversation got, the more a phone stuttered doing
  /// nothing in particular — the cost grew with history rather than with the
  /// change.
  ///
  /// Coalescing fixes the shape of that: a burst of receipts arriving together
  /// now writes once instead of once each, and the snapshot written is the last
  /// one, which is the only one that was ever going to survive anyway. The
  /// window is short enough to be invisible and the write still happens without
  /// anyone asking, so nothing downstream changes.
  final Map<String, List<Message>> _dirty = <String, List<Message>>{};
  Timer? _persistTimer;

  /// Long enough to swallow a burst, short enough that a kill in the gap costs
  /// nothing anyone would notice.
  static const Duration _persistDebounce = Duration(milliseconds: 400);

  void _persist(String peerId, List<Message> msgs) {
    if (_box == null) return;
    _dirty[peerId] = msgs;
    _persistTimer ??= Timer(_persistDebounce, () {
      _persistTimer = null;
      unawaited(flushPending());
    });
  }

  /// Write every pending conversation now.
  ///
  /// Public because a debounced write is a promise, and the two moments that
  /// can break it — the app going to the background, and the process being
  /// disposed — are both outside this class.
  Future<void> flushPending() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    final box = _box;
    if (box == null || _dirty.isEmpty) return;
    final batch = Map<String, List<Message>>.from(_dirty);
    _dirty.clear();
    for (final entry in batch.entries) {
      try {
        await box.put(entry.key, entry.value.map(_encode).toList());
      } catch (e) {
        debugPrint('Messages persist(${entry.key}) failed: $e');
      }
    }
  }

  /// The persistence codec, reachable from tests without a Hive box.
  ///
  /// What survives a restart is only checkable by round-tripping it, and doing
  /// that through a real encrypted box would test the keystore rather than the
  /// codec.
  @visibleForTesting
  static Map<String, dynamic> encodeForTest(Message m) => _encode(m);

  @visibleForTesting
  static Message decodeForTest(Map<String, dynamic> m) => _decode(m);

  static Map<String, dynamic> _encode(Message m) => {
        'id': m.id,
        'chatId': m.chatId,
        'text': m.text,
        'sentAtIso': m.sentAt.toIso8601String(),
        'isMine': m.isMine,
        'status': m.status.name,
        'kind': m.kind.name,
        if (m.imagePath != null) 'imagePath': m.imagePath,
        if (m.imageMime != null) 'imageMime': m.imageMime,
        if (m.audioPath != null) 'audioPath': m.audioPath,
        if (m.audioMime != null) 'audioMime': m.audioMime,
        if (m.audioDurationMs != null) 'audioDurationMs': m.audioDurationMs,
        if (m.filePath != null) 'filePath': m.filePath,
        if (m.fileName != null) 'fileName': m.fileName,
        if (m.fileBytes != null) 'fileBytes': m.fileBytes,
        if (m.forwardSecret) 'fs': true,
        if (m.wireId != null) 'wireId': m.wireId,
        if (m.authorName != null) 'author': m.authorName,
        if (m.authorId != null) 'authorId': m.authorId,
        if (m.editedAt != null) 'editedAtIso': m.editedAt!.toIso8601String(),
        if (m.readAt != null) 'readAtIso': m.readAt!.toIso8601String(),
        if (m.reactions.isNotEmpty)
          'reactions': {
            for (final e in m.reactions.entries) e.key: e.value.toList(),
          },
        if (m.readBy.isNotEmpty)
          'readBy': {
            for (final e in m.readBy.entries)
              e.key: {
                'name': e.value.name,
                'atIso': e.value.at.toIso8601String(),
              },
          },
        if (m.replyToWireId != null) 'replyTo': m.replyToWireId,
        if (m.replyPreview != null) 'replyPreview': m.replyPreview,
        if (m.route != null) 'route': m.route!.name,
        if (m.routeHops != null) 'routeHops': m.routeHops,
        if (m.pollOptions.isNotEmpty) 'pollOptions': m.pollOptions,
        if (m.pollVotes.isNotEmpty) 'pollVotes': m.pollVotes,
        if (m.viewOnce) 'viewOnce': true,
        // The record that survives a restart: without it, reopening the app
        // would show an opened photo as unopened again, minus its file.
        if (m.viewOnceConsumedAt != null)
          'viewOnceAtIso': m.viewOnceConsumedAt!.toIso8601String(),
      };

  static Message _decode(Map<String, dynamic> m) {
    final statusName = m['status'] as String? ?? 'delivered';
    final status = MessageStatus.values.firstWhere(
      (s) => s.name == statusName,
      orElse: () => MessageStatus.delivered,
    );
    final kindName = m['kind'] as String? ?? 'text';
    final kind = MessageKind.values.firstWhere(
      (k) => k.name == kindName,
      orElse: () => MessageKind.text,
    );
    final reactions = <String, Set<String>>{};
    final reactionsRaw = m['reactions'];
    if (reactionsRaw is Map) {
      reactionsRaw.forEach((k, v) {
        if (k is String && v is List) {
          reactions[k] = v.whereType<String>().toSet();
        }
      });
    }
    final readBy = <String, ChannelRead>{};
    final readByRaw = m['readBy'];
    if (readByRaw is Map) {
      readByRaw.forEach((k, v) {
        if (k is! String || v is! Map) return;
        final at = DateTime.tryParse((v['atIso'] as String?) ?? '');
        // A reader with no readable timestamp is dropped rather than given a
        // made-up one: the whole point of the entry is when they saw it.
        if (at == null) return;
        readBy[k] = ChannelRead(name: (v['name'] as String?) ?? '', at: at);
      });
    }
    return Message(
      id: m['id'] as String,
      chatId: m['chatId'] as String,
      text: m['text'] as String,
      sentAt: DateTime.tryParse((m['sentAtIso'] as String?) ?? '') ??
          DateTime.now(),
      isMine: (m['isMine'] as bool?) ?? false,
      status: status,
      kind: kind,
      // Repaired on the way out of storage, so every read site — bubbles,
      // viewers, playback, the share sheet — gets a path that resolves
      // against the container the app is in now. See [MediaPaths.repair].
      imagePath: MediaPaths.repairOrNull(m['imagePath'] as String?),
      imageMime: m['imageMime'] as String?,
      audioPath: MediaPaths.repairOrNull(m['audioPath'] as String?),
      audioMime: m['audioMime'] as String?,
      audioDurationMs: m['audioDurationMs'] as int?,
      filePath: MediaPaths.repairOrNull(m['filePath'] as String?),
      fileName: m['fileName'] as String?,
      fileBytes: m['fileBytes'] as int?,
      forwardSecret: (m['fs'] as bool?) ?? false,
      wireId: m['wireId'] as String?,
      authorName: m['author'] as String?,
      authorId: m['authorId'] as String?,
      editedAt: (m['editedAtIso'] as String?) == null
          ? null
          : DateTime.tryParse(m['editedAtIso'] as String),
      readAt: (m['readAtIso'] as String?) == null
          ? null
          : DateTime.tryParse(m['readAtIso'] as String),
      reactions: reactions,
      readBy: readBy,
      replyToWireId: m['replyTo'] as String?,
      replyPreview: m['replyPreview'] as String?,
      route: (m['route'] as String?) == null
          ? null
          : MessageRoute.values.firstWhere(
              (value) => value.name == m['route'],
              orElse: () => MessageRoute.queued,
            ),
      routeHops: m['routeHops'] as int?,
      pollOptions: (m['pollOptions'] as List?)
              ?.whereType<String>()
              .toList(growable: false) ??
          const <String>[],
      pollVotes: (m['pollVotes'] as Map?)?.map<String, int>(
            (key, value) => MapEntry(key as String, value as int),
          ) ??
          const <String, int>{},
      viewOnce: m['viewOnce'] as bool? ?? false,
      viewOnceConsumedAt: (m['viewOnceAtIso'] as String?) == null
          ? null
          : DateTime.tryParse(m['viewOnceAtIso'] as String),
    );
  }
}

final messagesControllerProvider =
    NotifierProvider<MessagesController, Map<String, List<Message>>>(
        MessagesController.new);
