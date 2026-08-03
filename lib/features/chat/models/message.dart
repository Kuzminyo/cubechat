import 'package:flutter/foundation.dart';

enum MessageStatus { sending, delivered, read, failed }

/// One person's acknowledgement that they have seen a channel message.
///
/// A channel has no member roster — holding the key *is* membership, joining
/// tells nobody, and a message goes out as a blind broadcast. So "who has read
/// this" can only ever be the people who said so; there is no denominator to
/// show a "3 of 5" against.
@immutable
class ChannelRead {
  const ChannelRead({required this.name, required this.at});

  /// The reader's display name as it resolved when their receipt arrived.
  ///
  /// Stored rather than looked up later, the same way [Message.authorName] is:
  /// the wire carries a signing-key fingerprint, and the widget drawing a
  /// bubble is the wrong place to be resolving one.
  final String name;

  /// Our own clock at the moment their receipt landed — not theirs.
  ///
  /// Same reasoning as [Message.readAt]: a timestamp supplied by the other side
  /// is neither trustworthy nor comparable with the rest of this timeline.
  final DateTime at;

  @override
  bool operator ==(Object other) =>
      other is ChannelRead && other.name == name && other.at == at;

  @override
  int get hashCode => Object.hash(name, at);
}

/// What kind of payload this message carries. Media messages keep their raw
/// bytes on disk (see [Message.mediaPath]) and use [text] only for an
/// optional caption / mime label shown in the bubble.
enum MessageKind { text, image, audio, file, poll }

enum MessageRoute { bluetooth, mesh, internet, queued }

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
    this.filePath,
    this.fileName,
    this.fileBytes,
    this.forwardSecret = false,
    this.wireId,
    this.authorName,
    this.authorId,
    this.editedAt,
    this.readAt,
    this.reactions = const <String, Set<String>>{},
    this.readBy = const <String, ChannelRead>{},
    this.replyToWireId,
    this.route,
    this.routeHops,
    this.pollOptions = const <String>[],
    this.pollVotes = const <String, int>{},
  });

  final String id;
  final String chatId;
  final String text;
  final DateTime sentAt;
  final bool isMine;
  final MessageStatus status;
  final MessageRoute? route;
  final int? routeHops;

  /// Poll choices and one signed vote per participant fingerprint. Polls are
  /// channel-only; [text] is the question and [wireId] is the poll id.
  final List<String> pollOptions;

  /// voter fingerprint (`me` locally) -> selected option index.
  final Map<String, int> pollVotes;
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

  /// When the recipient's read receipt for this message landed — our own clock,
  /// not theirs, since a peer's timestamp is neither trustworthy nor comparable
  /// with the rest of the timeline. Only ever set on our own outgoing messages
  /// ([status] == [MessageStatus.read] implies it), and surfaced in the
  /// long-press details rather than the bubble: it answers "when did they see
  /// this" without adding a second timestamp to every line of the chat.
  final DateTime? readAt;

  /// Emoji reactions attached to this message: emoji → set of reactor ids.
  /// A reactor id is `'me'` for the local user or a short sender fingerprint
  /// for a remote one, so counts stay correct and a reactor can toggle their
  /// own reaction off. Persisted as `{emoji: [reactorIds]}`.
  final Map<String, Set<String>> reactions;

  /// Who has acknowledged reading this message, keyed by a short fingerprint of
  /// the reader's Ed25519 signing key — the same identity channel authorship
  /// and reactions already use.
  ///
  /// Channels only. A 1:1 chat has exactly one possible reader, which [readAt]
  /// and [status] already say everything about; a map there would be one entry
  /// wide and two ways of storing the same fact.
  final Map<String, ChannelRead> readBy;

  /// [wireId] of the message this one quotes (a reply), or null. The UI looks
  /// the quoted message up in the store to render its snippet.
  final String? replyToWireId;

  // Image payload (M5.4).
  final String? imagePath;
  final String? imageMime;

  // Audio payload (voice messages).
  final String? audioPath;
  final String? audioMime;
  final int? audioDurationMs;

  // Arbitrary-file payload. Unlike images and voice notes, a file keeps the
  // name it was sent under — it is the only thing that says what the bubble is
  // and what it saves as. [fileBytes] is the size on disk, shown next to the
  // name so the recipient knows what they are about to open.
  final String? filePath;
  final String? fileName;
  final int? fileBytes;

  Message copyWith({
    MessageStatus? status,
    String? text,
    String? imagePath,
    String? audioPath,
    String? filePath,
    int? audioDurationMs,
    bool? forwardSecret,
    Map<String, Set<String>>? reactions,
    Map<String, ChannelRead>? readBy,
    DateTime? editedAt,
    DateTime? readAt,
    MessageRoute? route,
    int? routeHops,
    List<String>? pollOptions,
    Map<String, int>? pollVotes,
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
      filePath: filePath ?? this.filePath,
      fileName: fileName,
      fileBytes: fileBytes,
      audioMime: audioMime,
      audioDurationMs: audioDurationMs ?? this.audioDurationMs,
      forwardSecret: forwardSecret ?? this.forwardSecret,
      wireId: wireId,
      authorName: authorName,
      authorId: authorId,
      editedAt: editedAt ?? this.editedAt,
      readAt: readAt ?? this.readAt,
      reactions: reactions ?? this.reactions,
      readBy: readBy ?? this.readBy,
      replyToWireId: replyToWireId,
      route: route ?? this.route,
      routeHops: routeHops ?? this.routeHops,
      pollOptions: pollOptions ?? this.pollOptions,
      pollVotes: pollVotes ?? this.pollVotes,
    );
  }
}
