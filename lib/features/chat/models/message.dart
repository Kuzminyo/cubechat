import 'package:flutter/foundation.dart';

enum MessageStatus { sending, delivered, read, failed }

/// What kind of payload this message carries. Media messages keep their raw
/// bytes on disk (see [Message.mediaPath]) and use [text] only for an
/// optional caption / mime label shown in the bubble.
enum MessageKind { text, image, audio }

@immutable
class Message {
  const Message({
    required this.id,
    required this.chatId,
    required this.text,
    required this.sentAt,
    required this.isMine,
    this.status = MessageStatus.delivered,
    this.kind = MessageKind.text,
    this.imagePath,
    this.imageMime,
    this.audioPath,
    this.audioMime,
    this.audioDurationMs,
    this.forwardSecret = false,
    this.wireId,
    this.authorName,
    this.authorId,
    this.editedAt,
    this.reactions = const <String, Set<String>>{},
  });

  final String id;
  final String chatId;
  final String text;
  final DateTime sentAt;
  final bool isMine;
  final MessageStatus status;

  final MessageKind kind;

  /// True when this message was encrypted with a per-message forward-secret
  /// key (X3DH), as opposed to the long-term-key SealedBox path. Surfaced in
  /// the bubble as a small shield so the user can see the stronger guarantee.
  final bool forwardSecret;

  /// Hex of the 16-byte transport [TransportEnvelope.msgId] this message was
  /// carried under. Both the sender (who mints it) and the receiver (who reads
  /// it off the envelope) record the *same* value, giving read receipts and
  /// reactions a stable cross-device handle for "that message". Null for
  /// legacy rows and media (which we don't ack / react to).
  final String? wireId;

  /// For channel messages received from others: the resolved display name of
  /// the author (a channel bucket mixes many senders). Null in 1:1 chats,
  /// where the whole conversation is one peer.
  final String? authorName;

  /// Stable fingerprint of the author, for channel messages: a short hex of
  /// their Ed25519 signing key. It's what an inbound edit is checked against —
  /// display names are not identities. Null in 1:1 chats, where "not mine"
  /// already identifies the sender.
  final String? authorId;

  /// When the author last rewrote this message, or null if never edited.
  final DateTime? editedAt;

  /// Emoji reactions attached to this message: emoji → set of reactor ids.
  /// A reactor id is `'me'` for the local user or a short sender fingerprint
  /// for a remote one, so counts stay correct and a reactor can toggle their
  /// own reaction off. Persisted as `{emoji: [reactorIds]}`.
  final Map<String, Set<String>> reactions;

  // Image payload (M5.4).
  final String? imagePath;
  final String? imageMime;

  // Audio payload (voice messages).
  final String? audioPath;
  final String? audioMime;
  final int? audioDurationMs;

  Message copyWith({
    MessageStatus? status,
    String? text,
    String? imagePath,
    String? audioPath,
    int? audioDurationMs,
    bool? forwardSecret,
    Map<String, Set<String>>? reactions,
    DateTime? editedAt,
  }) {
    return Message(
      id: id,
      chatId: chatId,
      text: text ?? this.text,
      sentAt: sentAt,
      isMine: isMine,
      status: status ?? this.status,
      kind: kind,
      imagePath: imagePath ?? this.imagePath,
      imageMime: imageMime,
      audioPath: audioPath ?? this.audioPath,
      audioMime: audioMime,
      audioDurationMs: audioDurationMs ?? this.audioDurationMs,
      forwardSecret: forwardSecret ?? this.forwardSecret,
      wireId: wireId,
      authorName: authorName,
      authorId: authorId,
      editedAt: editedAt ?? this.editedAt,
      reactions: reactions ?? this.reactions,
    );
  }
}
