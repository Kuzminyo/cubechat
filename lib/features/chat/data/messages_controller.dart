import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

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
      final box = await Hive.openBox<List<dynamic>>(HiveBoxes.messages);
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
        if (m.videoPath != null) 'videoPath': m.videoPath,
        if (m.videoMime != null) 'videoMime': m.videoMime,
        if (m.videoDurationMs != null) 'videoDurationMs': m.videoDurationMs,
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
      videoPath: m['videoPath'] as String?,
      videoMime: m['videoMime'] as String?,
      videoDurationMs: m['videoDurationMs'] as int?,
    );
  }
}

final messagesControllerProvider =
    NotifierProvider<MessagesController, Map<String, List<Message>>>(MessagesController.new);
