import 'package:characters/characters.dart';
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

/// The latest moment anything in [history] was *sent*.
///
/// Not `history.last.sentAt`, which is what the chat screen used to hand the
/// read marker. That is the last message to **arrive**, and since 956 a message
/// carries the sender's clock rather than the moment it landed — so a batch
/// delivered out of order, which is every relay backlog and every burst spread
/// across three relays, routinely ends on a message stamped earlier than one
/// already in the list.
///
/// The read marker never moves backwards, by design. Set from the wrong end it
/// therefore sticks below its own conversation, and every message above it
/// reads as unread for ever — "open the chat, one or two go blue, the rest stay
/// unread on the tile, and only mark-as-read clears them". That button works
/// because it passes no timestamp at all and gets `now()`.
///
/// Null for an empty history, which has no newest anything.
DateTime? newestSentAt(List<Message> history) {
  if (history.isEmpty) return null;
  var newest = history.first.sentAt;
  for (final m in history) {
    if (m.sentAt.isAfter(newest)) newest = m.sentAt;
  }
  return newest;
}

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
    this.audioLevels,
    this.forwardedFrom,
    this.forwardedFromId,
    this.mediaId,
    this.voicePlayed = false,
    this.expiresAt,
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
    this.replyPreview,
    this.route,
    this.routeHops,
    this.pollOptions = const <String>[],
    this.pollVotes = const <String, int>{},
    this.viewOnce = false,
    this.viewOnceConsumedAt,
    this.albumId,
  });

  /// The set of photos this one was sent with, for the ones we sent ourselves.
  ///
  /// `sendImageBatch` stamps one id across everything it was handed, so the
  /// boundary is recorded at the only moment anything actually knows where it
  /// is, rather than re-derived afterwards from timestamps that no longer say.
  /// Without it, grouping falls back to "same sender, close together", which
  /// is a guess, and the guess was wrong in the obvious case: five photos,
  /// then five more a minute later, are two batches to the person who sent
  /// them and one uninterrupted run of ten to a rule that only looks at gaps.
  /// They came out as a grid of nine — the grid's own limit — and a tenth
  /// photo on its own underneath.
  ///
  /// The id itself never travels. A received photo gets one when its sender
  /// sent an [AlbumHint] naming the batch — the hint carries media ids, and
  /// the receiver mints its own id for the set — so the two sides agree on
  /// where the batch ended without agreeing on what to call it. A photo from
  /// a build that predates the hint still has none, and still falls back to
  /// the gap rule.
  final String? albumId;

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

  /// [wireId] of the message this one quotes (a reply), or null.
  final String? replyToWireId;

  /// What the quoted message looked like when the reply was written.
  ///
  /// The quote box used to be rendered entirely by looking the target up in the
  /// store, and drew a bare "…" whenever the lookup missed — which is not a
  /// rare case: the history may have been cleared, the two messages may be
  /// filed under different ids, or the quoted one may simply not have arrived
  /// yet. Replying to a sticker showed "…" every time, which is what prompted
  /// this.
  ///
  /// Kept alongside the id rather than instead of it: the id is what a tap on
  /// the quote jumps to, and the text is what the quote *says*. One is
  /// navigation and the other is content, and only the second of them has to
  /// survive the message it points at.
  ///
  /// Null on a reply that arrived over the wire — nothing carries it there —
  /// so the lookup remains the fallback rather than the other way round.
  final String? replyPreview;

  // Image payload (M5.4).
  final String? imagePath;
  final String? imageMime;

  // Audio payload (voice messages).
  final String? audioPath;
  final String? audioMime;
  final int? audioDurationMs;

  /// When this one message stops being kept, or null for "as long as the
  /// chat keeps it".
  ///
  /// Auto-delete is a rule for a whole conversation and this is a rule for one
  /// line in it — the sentence you would rather not leave lying around, in a
  /// chat you otherwise want whole.
  ///
  /// Local, like auto-delete itself: nothing about either goes on the wire, so
  /// two people in the same chat each keep their own copy on their own terms.
  /// It is a note to this device, not a demand on theirs — and a demand is
  /// what it could never honestly be, since a copy that has arrived is theirs.
  final DateTime? expiresAt;

  /// Whether this voice note has been listened to on this device.
  ///
  /// Local and never on the wire: it answers "have *I* heard this yet", which
  /// is a different question from the read receipt the sender gets. A note
  /// opened on one phone is still unplayed on another, and that is correct.
  final bool voicePlayed;

  /// Loudness per bar, 0..255, or null when the sender did not say.
  ///
  /// Null is the ordinary case for anything recorded before this existed and
  /// for anything sent by a build that predates it, so the bubble has to be
  /// able to draw a voice note without it — see [VoiceLevels], which travels
  /// as its own payload precisely so an old build loses this and keeps the
  /// audio.
  final List<int>? audioLevels;

  /// The name of whoever wrote this before it was forwarded, or null.
  ///
  /// A claim by the person who forwarded it rather than a proof: the name
  /// travelled with their message, not with a signature over it. Local to this
  /// device once it lands, exactly like the voice levels beside it.
  final String? forwardedFrom;

  /// The original author's canonical id (X25519 hex), when they allow being
  /// reached through a forward of their own words.
  ///
  /// What turns the line above the bubble from a piece of text into a way to
  /// open somebody's profile. Absent for a forward from an older build, and
  /// deliberately absent when the author asked not to be linked — see
  /// [InnerPayloadType.forwardPrivacy]. Both read the same way: a name, going
  /// nowhere.
  ///
  /// [selfAuthorId] when the words are ours. Our own key would be wrong here
  /// even though it is exactly what goes out on the wire: that key names a
  /// *contact* to every other phone, and this one holds no contact card for
  /// itself — following it would open a profile of a stranger wearing our
  /// name. The marker is what sends the tap to our own profile instead.
  final String? forwardedFromId;

  /// Stands in for our own key in [forwardedFromId]. Local only; on the wire
  /// the real key travels, so the phone receiving the forward opens us the
  /// ordinary way.
  static const String selfAuthorId = 'self';

  /// The 16-byte media id this attachment travelled under, in hex.
  ///
  /// Kept because it is the only thing that makes a picture re-sendable
  /// *without* everybody seeing it twice. A message's [wireId] is the hash of
  /// this id, and insertion is idempotent on the wireId — so a replay minted
  /// with a fresh id is a new message to every phone in the room, and a replay
  /// carrying the original id lands only where the picture is missing.
  ///
  /// Null for text, and for anything stored before this field existed: those
  /// pictures cannot be replayed, and the history offer simply passes over
  /// them rather than duplicating them for the whole room.
  final String? mediaId;

  // Arbitrary-file payload. Unlike images and voice notes, a file keeps the
  // name it was sent under — it is the only thing that says what the bubble is
  // and what it saves as. [fileBytes] is the size on disk, shown next to the
  // name so the recipient knows what they are about to open.
  final String? filePath;
  final String? fileName;
  final int? fileBytes;

  /// A photo meant to be opened once. See [MediaManifest.viewOnce].
  final bool viewOnce;

  /// When the photo was actually opened — on the recipient's side by looking
  /// at it, on the sender's by being told they did. Non-null means the bytes
  /// are gone and the bubble is a tombstone.
  ///
  /// The row itself deliberately outlives the picture. Its [wireId] is what
  /// makes [MessagesController.append] absorb a re-delivered manifest — a
  /// relay replaying the transfer, say — into the already-opened bubble
  /// instead of quietly reviving a viewable one.
  final DateTime? viewOnceConsumedAt;

  bool get viewOnceConsumed => viewOnceConsumedAt != null;

  /// What was typed under a photo, or null when nothing was.
  ///
  /// A photo's caption travels in [text], because the media manifest has
  /// nowhere else to carry one — but that field doubles as the place a mime
  /// type lands when there is no caption, and history written by older builds
  /// is full of `image/jpeg` sitting exactly where a caption would. So anything
  /// shaped like a mime type is not a caption, and neither is whitespace.
  ///
  /// This exists because the caption was being *sent* correctly and never
  /// drawn: the bubble picks its body with an if/else chain on the message
  /// kind, an image took the image branch, and the branch that renders text sat
  /// after it in the same chain. The caption made the trip and then had nowhere
  /// on screen to land.
  String? get imageCaption {
    final t = text.trim();
    if (t.isEmpty) return null;
    if (t.startsWith('image/') || t.startsWith('audio/')) return null;
    if (t.startsWith(stickerMarker)) return null;
    return t;
  }

  /// What a sticker says in the caption field instead of a caption.
  ///
  /// A sticker is a picture, and it travels as one: the whole media path —
  /// chunking, encryption, mesh relay, reassembly, the store-and-forward
  /// buffer — already carries pictures across this network reliably, and none
  /// of it needed a second kind of thing to learn. What makes it a sticker is
  /// this one word riding where a caption would, which is the same trick the
  /// map beacons and contact cards use for small facts.
  ///
  /// A build that has never heard of stickers therefore shows a photo with an
  /// odd line under it, rather than nothing at all.
  static const String stickerMarker = 'cubechat:sticker:v1';

  /// The marker for a sticker that was given a face: `…:v1:😀`.
  ///
  /// The emoji is what a sticker is *called* — it is what the chat list and a
  /// reply quote show in place of a picture they cannot draw, because "🔥" says
  /// what was sent and "cubechat:sticker:v1" says only that the reader is
  /// looking at plumbing. It rides in the same field for the same reason the
  /// marker does: no new payload type, and an older build shows a picture with
  /// an odd line under it rather than nothing.
  static String stickerMarkerFor(String? emoji) =>
      emoji == null || emoji.isEmpty ? stickerMarker : '$stickerMarker:$emoji';

  /// Drawn without a bubble, larger, and with no caption line — the way every
  /// messenger draws one.
  bool get isSticker =>
      kind == MessageKind.image && text.trim().startsWith(stickerMarker);

  /// How many emoji this message is, when it is nothing else.
  ///
  /// Null for anything with a word in it. A message that is only emoji is drawn
  /// the way every messenger draws one — large, and with no bubble around it —
  /// because a bubble is a frame for text and there is no text here. Asked for
  /// against Telegram, where two laughing faces come out as two big faces and
  /// nothing else.
  ///
  /// Capped at [maxBareEmoji]: past a handful they stop being a reaction and
  /// start being a message, and a wall of forty at sticker size is a screenful.
  /// Those keep the bubble and the ordinary size.
  ///
  /// Counted in grapheme clusters, not runes. A single emoji is routinely
  /// several code points — a skin tone is a modifier, a family is people joined
  /// by zero-width joiners, a flag is two regional indicators — and counting
  /// runes would call one waving hand three emoji and refuse to enlarge it.
  int? get bareEmojiCount {
    final t = text.trim();
    if (t.isEmpty) return null;
    var count = 0;
    for (final cluster in t.characters) {
      // Spaces between them are still nothing but emoji. People type "😀 😀"
      // as readily as "😀😀" and mean the same thing by it.
      if (cluster.trim().isEmpty) continue;
      if (!_isEmojiCluster(cluster)) return null;
      count++;
      if (count > maxBareEmoji) return null;
    }
    return count == 0 ? null : count;
  }

  /// Past this many, an emoji message is a message again.
  static const int maxBareEmoji = 3;

  /// Whether a grapheme cluster is made only of emoji and their joinery.
  ///
  /// Deliberately a check on the cluster's parts rather than a regex over the
  /// whole string: the joiners, variation selectors and skin-tone modifiers
  /// that hold one emoji together are not themselves emoji, and a rule written
  /// as "every rune is in an emoji block" rejects every emoji that is more than
  /// one rune — which is most of the ones people actually send.
  static bool _isEmojiCluster(String cluster) {
    var sawPictograph = false;
    for (final rune in cluster.runes) {
      if (_isJoinery(rune)) continue;
      if (!_isPictograph(rune)) return false;
      sawPictograph = true;
    }
    return sawPictograph;
  }

  /// Zero-width joiner, variation selectors, skin tones and keycap marks: the
  /// glue inside an emoji, meaningless on their own.
  static bool _isJoinery(int rune) =>
      rune == 0x200D || // zero-width joiner
      rune == 0xFE0F || // variation selector-16, "draw this as emoji"
      rune == 0xFE0E ||
      rune == 0x20E3 || // combining enclosing keycap
      (rune >= 0x1F3FB && rune <= 0x1F3FF); // skin tones

  static bool _isPictograph(int rune) =>
      (rune >= 0x1F300 && rune <= 0x1FAFF) || // the main emoji planes
      (rune >= 0x2600 && rune <= 0x27BF) || // misc symbols and dingbats
      (rune >= 0x1F000 && rune <= 0x1F2FF) || // mahjong, cards, enclosed
      (rune >= 0x1F1E6 && rune <= 0x1F1FF) || // regional indicators, for flags
      rune == 0x2B50 ||
      rune == 0x2B55 ||
      (rune >= 0x2190 && rune <= 0x21FF) || // arrows drawn as emoji
      (rune >= 0x2B00 && rune <= 0x2BFF);

  /// The emoji this sticker was filed under, or null for one sent before they
  /// had any (or by a build that does not set them).
  String? get stickerEmoji {
    if (!isSticker) return null;
    final rest = text.trim().substring(stickerMarker.length);
    if (!rest.startsWith(':')) return null;
    final emoji = rest.substring(1).trim();
    return emoji.isEmpty ? null : emoji;
  }

  Message copyWith({
    MessageStatus? status,
    String? text,
    String? imagePath,
    String? audioPath,
    String? filePath,
    int? audioDurationMs,
    List<int>? audioLevels,
    String? forwardedFrom,
    String? forwardedFromId,
    String? mediaId,
    bool? voicePlayed,
    DateTime? expiresAt,
    bool clearExpiry = false,
    bool? forwardSecret,
    Map<String, Set<String>>? reactions,
    Map<String, ChannelRead>? readBy,
    DateTime? editedAt,
    DateTime? readAt,
    MessageRoute? route,
    int? routeHops,
    List<String>? pollOptions,
    Map<String, int>? pollVotes,
    DateTime? viewOnceConsumedAt,
    String? albumId,
    /// Every other nullable here is "leave it alone when null", which gives no
    /// way to *un*set a path. Consuming a view-once photo needs exactly that.
    bool clearImagePath = false,
  }) {
    return Message(
      id: id,
      chatId: chatId,
      text: text ?? this.text,
      sentAt: sentAt,
      isMine: isMine,
      status: status ?? this.status,
      kind: kind,
      imagePath: clearImagePath ? null : (imagePath ?? this.imagePath),
      imageMime: imageMime,
      audioPath: audioPath ?? this.audioPath,
      filePath: filePath ?? this.filePath,
      fileName: fileName,
      fileBytes: fileBytes,
      audioMime: audioMime,
      audioDurationMs: audioDurationMs ?? this.audioDurationMs,
      audioLevels: audioLevels ?? this.audioLevels,
      forwardedFrom: forwardedFrom ?? this.forwardedFrom,
      forwardedFromId: forwardedFromId ?? this.forwardedFromId,
      mediaId: mediaId ?? this.mediaId,
      voicePlayed: voicePlayed ?? this.voicePlayed,
      expiresAt: clearExpiry ? null : (expiresAt ?? this.expiresAt),
      forwardSecret: forwardSecret ?? this.forwardSecret,
      wireId: wireId,
      authorName: authorName,
      authorId: authorId,
      editedAt: editedAt ?? this.editedAt,
      readAt: readAt ?? this.readAt,
      reactions: reactions ?? this.reactions,
      readBy: readBy ?? this.readBy,
      replyToWireId: replyToWireId,
      replyPreview: replyPreview,
      route: route ?? this.route,
      routeHops: routeHops ?? this.routeHops,
      pollOptions: pollOptions ?? this.pollOptions,
      pollVotes: pollVotes ?? this.pollVotes,
      viewOnce: viewOnce,
      viewOnceConsumedAt: viewOnceConsumedAt ?? this.viewOnceConsumedAt,
      albumId: albumId ?? this.albumId,
    );
  }
}
