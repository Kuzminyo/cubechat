import 'dart:math' as math;

import '../models/message.dart';

/// Photos that were sent together, folded into one bubble.
///
/// A batch of pictures is not a batch on the wire: the picker sends each one as
/// its own message, and the transcript drew each one as its own bubble — nine
/// photos of the same snowfall came out as nine stacked squares that pushed
/// everything either side of them off the screen, and the caption, which
/// belongs to the set, sat under the first of them looking like a comment on
/// that one picture.
///
/// Nothing about this changes what is sent or stored. The grouping is derived
/// on the way to the screen from what the messages already say, which also
/// means every batch anybody has already sent or received groups itself the
/// moment this build opens the conversation.
class PhotoAlbums {
  const PhotoAlbums._(this._byAnchor, this._folded);

  const PhotoAlbums.empty()
      : _byAnchor = const {},
        _folded = const {};

  final Map<String, List<Message>> _byAnchor;
  final Set<String> _folded;

  /// The album this message opens, or null when it is not the start of one.
  List<Message>? albumAt(String messageId) => _byAnchor[messageId];

  /// True for the photos drawn inside somebody else's album, which the list
  /// must therefore not draw again.
  bool isFolded(String messageId) => _folded.contains(messageId);

  bool get isEmpty => _byAnchor.isEmpty;
}

/// How many photos fit in one album before the next one starts.
///
/// Nine is the grid's own limit — three rows of three is as much as can be
/// shown without the cells becoming too small to tell apart. A tenth photo
/// opens a second album rather than being hidden behind a "+1".
const int kMaxAlbumPhotos = 9;

/// How far apart two photos may be and still count as one batch.
///
/// A picker sends its photos as fast as the encoder manages, which on a large
/// picture over a slow mesh is not fast — but it is uninterrupted, and that is
/// what this measures. Long enough to cover a set of heavy photos; short
/// enough that a picture sent later, as a reply to something said in between,
/// stays its own message.
///
/// **Ninety seconds again, and this time it means ninety seconds.**
///
/// It was widened to five minutes because a received photo was stamped when its
/// last chunk landed rather than when it was sent, so the gap between two of
/// them included the whole transfer of the first — two pictures sent together
/// from an iPhone over Bluetooth arrived four minutes apart and drew as two
/// bubbles. That note ended "the proper fix is a timestamp in the manifest",
/// and the proper fix is now in: every received message and every received
/// photo is stamped from the sender's own signed timestamp, which has been on
/// the wire all along and was only ever read to reject things.
///
/// So this measures what it says again — time between two photos being *sent* —
/// and the five minutes it needed while it was measuring transfers is now the
/// thing that folds two separate sends into one album.
const Duration kAlbumWindow = Duration(seconds: 90);

/// How close the *second* photo has to be for a run to open at all.
///
/// A run holding one photo has no rhythm to be judged against, so [kAlbumWindow]
/// was the only test — and any two single photos inside it were folded together
/// however much had happened in between. Reported as: one person sends a photo,
/// the other sends photos, the first sends one more, and it attaches to their
/// first.
///
/// A picker sends its batch as fast as it can encode, and in *sent* time that
/// is seconds. A person who sends one picture, watches somebody answer, and
/// sends another has taken far longer than that, whatever the link was doing.
/// Twenty seconds tells those apart and needs no heuristic about what happened
/// in between — which was tried, and broke the case two people sending batches
/// at the same time exist to keep working.
///
/// This is only ever the fallback. A batch of two or more announces itself
/// ([Message.albumId], `AlbumHint`), and that answer wins outright above.
const Duration kAlbumOpeningGap = Duration(seconds: 20);

/// Fold consecutive photos from one sender into albums.
///
/// [messages] must be in conversation order, oldest first. The album is
/// anchored on its *first* photo, so it keeps the place in the conversation
/// where the batch began and does not jump about as the rest of it arrives.
///
/// What breaks a run, and why:
///
///   * anything that is not a plain photo — a word between two pictures means
///     they were sent about different things, and it breaks *everyone's* run,
///     because a sentence in the middle is a real break in the conversation;
///   * a view-once photo, which is deliberately never drawn as a thumbnail and
///     has no business inside a grid of them;
///   * more than [kAlbumWindow] of silence, or [kMaxAlbumPhotos] already in
///     hand.
///
/// What does **not** break a run, and why it used to: somebody else's photos
/// landing in the middle of this one's. A run was previously required to be
/// adjacent in the merged list, and two people sending a batch at the same time
/// interleave in it — so each batch was shredded into single bubbles. It showed
/// up as the asymmetry in the report: *your own* five photos always grouped,
/// because [MessagingService.prepareImage] mints all their bubbles in one go
/// before any byte is sent, while the five coming the other way are stamped as
/// each one's last chunk lands, spread across minutes, with yours in between.
/// Same conversation, two devices, one of them a tidy grid and the other a
/// column.
///
/// So a run is now per sender, and several are open at once. Folding them still
/// anchors each album at its own first photo, so the two batches keep their
/// places relative to each other; all that changes is that neither is cut up by
/// the other. Note this deliberately reorders nothing that was really said in
/// between — the interleaving is an artefact of how long a transfer took, not
/// of when the pictures were sent.
PhotoAlbums groupPhotoAlbums(List<Message> messages) {
  if (messages.length < 2) return const PhotoAlbums.empty();

  final byAnchor = <String, List<Message>>{};
  final folded = <String>{};
  // Keyed by sender, so two people mid-batch each keep their own run. Ordered
  // by insertion, which is the order their first photos appeared — the same
  // order the anchors will sit in.
  final runs = <String, List<Message>>{};

  void flush(String sender) {
    final run = runs.remove(sender);
    if (run == null || run.length < 2) return;
    byAnchor[run.first.id] = List.unmodifiable(run);
    for (final message in run.skip(1)) {
      folded.add(message.id);
    }
  }

  void flushAll() {
    for (final sender in runs.keys.toList()) {
      flush(sender);
    }
  }

  for (final message in messages) {
    if (!_albumable(message)) {
      flushAll();
      continue;
    }
    final sender = _senderKey(message);
    final run = runs[sender];
    if (run != null && !_joins(run, message)) {
      flush(sender);
    }
    (runs[sender] ??= <Message>[]).add(message);
  }
  flushAll();

  if (byAnchor.isEmpty) return const PhotoAlbums.empty();
  return PhotoAlbums._(byAnchor, folded);
}

/// Who sent this, as far as albums are concerned.
///
/// The prefix is an escape rather than a literal NUL byte in the source. It
/// was a literal one, which made this file binary to every tool that samples
/// for it — `grep` refused to print matches, and a text round-trip through the
/// wrong encoding would have silently eaten it and quietly merged our own run
/// with an anonymous peer's. `\u0000` is the same character and survives being
/// handled.
///
/// [Message.isMine] alone is not enough in a channel, where several authors
/// share one bucket; [Message.authorId] alone is not enough in a 1:1 chat,
/// where our own messages carry none.
String _senderKey(Message message) =>
    message.isMine ? '\u0000mine' : (message.authorId ?? '\u0000them');

bool _albumable(Message message) =>
    message.kind == MessageKind.image &&
    !message.isSticker &&
    !message.viewOnce &&
    message.imagePath != null;

/// Whether [next] belongs to the run [previous] ends.
///
/// The sender is not re-checked here: runs are keyed by [_senderKey], so both
/// arguments are the same person by construction.
///
/// [Message.albumId] wins outright when either side has one. It says exactly
/// where a batch starts and stops, so five photos followed a minute later by
/// five more are two albums rather than the grid of nine plus a straggler the
/// gap rule produced.
///
/// It is set on what we sent ourselves, and on what we received when the
/// sender announced the batch (`AlbumHint`, an inner payload carrying the
/// media ids). A photo from a peer running a build older than that hint has
/// none, and falls back to the gap — which is what every received photo used
/// to do.
bool _joins(List<Message> run, Message next) {
  if (run.length >= kMaxAlbumPhotos) return false;
  final previous = run.last;
  final a = previous.albumId;
  final b = next.albumId;
  if (a != null || b != null) return a == b;

  final gap = next.sentAt.difference(previous.sentAt).abs();
  if (gap > kAlbumWindow) return false;
  if (run.length < 2) return gap <= kAlbumOpeningGap;

  // The batch's own rhythm, rather than one window for every link.
  //
  // A batch arrives at whatever pace the transport manages — a second apart
  // over the relay, a minute apart over Bluetooth — and it is *even*, because
  // nothing is happening between the photos except the transfer. A second
  // batch, sent by a person who did something else first, opens with a gap
  // that stands out against that pace however slow the link was.
  //
  // The fixed window could not see this. Five photos, a sentence, five more
  // came out as a grid of nine and a straggler, because the sentence is tiny
  // and arrives while the photos are still transferring — so it is stamped
  // *before* them and never lands between the two runs at all. Ordering by
  // arrival cannot separate them; pace can.
  //
  // Four times the median gap, floored at 45 s so a burst of near-instant
  // photos does not split on ordinary jitter.
  final gaps = <int>[
    for (var i = 1; i < run.length; i++)
      run[i].sentAt.difference(run[i - 1].sentAt).abs().inMilliseconds,
  ]..sort();
  final median = gaps[gaps.length ~/ 2];
  final limit = math.max(median * 4, 45000);
  return gap.inMilliseconds <= limit;
}
