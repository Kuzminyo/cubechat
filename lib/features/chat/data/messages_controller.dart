import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../../core/storage/hive_cipher.dart';
import '../../../core/storage/hive_init.dart';
import '../models/message.dart';

/// Per-peer message store, keyed by the canonical chat id (the peer's
/// pubkeyHex once the handshake has authenticated them).
///
/// Backed by Hive (M4) so chat history survives app restarts. Each entry in
/// the box is a `List<Map<String, dynamic>>` of messages — simple, schema-
/// stable, no codegen TypeAdapter required.
class MessagesController extends Notifier<Map<String, List<Message>>> {
  Box<List<dynamic>>? _box;

  @override
  Map<String, List<Message>> build() {
    unawaited(_loadFromDisk());
    return <String, List<Message>>{};
  }

  Future<void> _loadFromDisk() async {
    try {
      final box = await hiveCipherProvider
          .openEncryptedBox<List<dynamic>>(HiveBoxes.messages);
      _box = box;
      final loaded = <String, List<Message>>{};
      for (final key in box.keys) {
        final raw = box.get(key);
        if (raw == null) continue;
        try {
          loaded[key as String] = raw
              .map((dynamic m) => _decode((m as Map).cast<String, dynamic>()))
              .toList();
        } catch (e) {
          debugPrint('skip corrupt messages bucket "$key": $e');
        }
      }
      if (loaded.isNotEmpty) {
        state = {...loaded, ...state};
      }
    } catch (e, st) {
      debugPrint('Messages load failed: $e\n$st');
    }
  }

  List<Message> forPeer(String peerId) => state[peerId] ?? const <Message>[];

  void append(String peerId, Message msg) {
    final current = state[peerId] ?? const <Message>[];
    final next = [...current, msg];
    state = {...state, peerId: next};
    _persist(peerId, next);
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

  /// Flip our own outgoing messages to [MessageStatus.read] when the peer's
  /// read receipt lands. Messages are matched by their transport [wireId]
  /// (the id both sides share); non-mine messages and already-read ones are
  /// left untouched. No-op when nothing matched (idempotent under resends).
  void markRead(String peerId, Set<String> wireIds) {
    final current = state[peerId];
    if (current == null || wireIds.isEmpty) return;
    var changed = false;
    final list = [...current];
    for (var i = 0; i < list.length; i++) {
      final m = list[i];
      if (m.isMine &&
          m.wireId != null &&
          m.status != MessageStatus.read &&
          wireIds.contains(m.wireId)) {
        list[i] = m.copyWith(status: MessageStatus.read);
        changed = true;
      }
    }
    if (!changed) return;
    state = {...state, peerId: list};
    _persist(peerId, list);
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

    final list = [...current]
      ..[idx] = m.copyWith(text: text, editedAt: DateTime.now());
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

  /// Flags an outgoing message as forward-secret once the send path has
  /// confirmed the X3DH cipher was actually used (the placeholder is
  /// appended before the body is built).
  void markForwardSecret(String peerId, String msgId) {
    final current = state[peerId];
    if (current == null) return;
    final idx = current.indexWhere((m) => m.id == msgId);
    if (idx == -1) return;
    if (current[idx].forwardSecret) return;
    final list = [...current]
      ..[idx] = current[idx].copyWith(forwardSecret: true);
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
    final list = [...current]
      ..[idx] = current[idx].copyWith(imagePath: imagePath, status: status);
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
    final list = [...current]
      ..[idx] = current[idx].copyWith(
        audioPath: audioPath,
        audioDurationMs: durationMs,
        status: status,
      );
    state = {...state, peerId: list};
    _persist(peerId, list);
  }

  /// Erase every conversation — used by Emergency Wipe.
  Future<void> clearAll() async {
    state = <String, List<Message>>{};
    try {
      await _box?.clear();
    } catch (e) {
      debugPrint('Messages box clear failed: $e');
    }
  }

  /// Erase a single chat (the `/clear` IRC command).
  Future<void> clearForChat(String chatId) async {
    if (!state.containsKey(chatId)) return;
    state = {...state}..remove(chatId);
    try {
      await _box?.delete(chatId);
    } catch (e) {
      debugPrint('Messages delete($chatId) failed: $e');
    }
  }

  Future<void> _persist(String peerId, List<Message> msgs) async {
    final box = _box;
    if (box == null) return;
    try {
      await box.put(peerId, msgs.map(_encode).toList());
    } catch (e) {
      debugPrint('Messages persist($peerId) failed: $e');
    }
  }

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
        if (m.forwardSecret) 'fs': true,
        if (m.wireId != null) 'wireId': m.wireId,
        if (m.authorName != null) 'author': m.authorName,
        if (m.authorId != null) 'authorId': m.authorId,
        if (m.editedAt != null) 'editedAtIso': m.editedAt!.toIso8601String(),
        if (m.reactions.isNotEmpty)
          'reactions': {
            for (final e in m.reactions.entries) e.key: e.value.toList(),
          },
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
    return Message(
      id: m['id'] as String,
      chatId: m['chatId'] as String,
      text: m['text'] as String,
      sentAt: DateTime.tryParse((m['sentAtIso'] as String?) ?? '') ??
          DateTime.now(),
      isMine: (m['isMine'] as bool?) ?? false,
      status: status,
      kind: kind,
      imagePath: m['imagePath'] as String?,
      imageMime: m['imageMime'] as String?,
      audioPath: m['audioPath'] as String?,
      audioMime: m['audioMime'] as String?,
      audioDurationMs: m['audioDurationMs'] as int?,
      forwardSecret: (m['fs'] as bool?) ?? false,
      wireId: m['wireId'] as String?,
      authorName: m['author'] as String?,
      authorId: m['authorId'] as String?,
      editedAt: (m['editedAtIso'] as String?) == null
          ? null
          : DateTime.tryParse(m['editedAtIso'] as String),
      reactions: reactions,
    );
  }
}

final messagesControllerProvider =
    NotifierProvider<MessagesController, Map<String, List<Message>>>(MessagesController.new);
