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
/// Five minutes, not ninety seconds, because a received photo is stamped when
/// its last chunk lands rather than when it was sent — nothing on the wire
/// carries the sender's clock — so the gap between two of them includes the
/// whole transfer of the first. Two pictures sent together from an iPhone over
/// Bluetooth arrived four minutes apart and drew as two bubbles, while the
/// same pair over a fast link grouped correctly. The proper fix is a timestamp
/// in the manifest; this stops the display depending on the link speed.
const Duration kAlbumWindow = Duration(minutes: 5);

/// Fold consecutive photos from one sender into albums.
///
/// [messages] must be in conversation order, oldest first. The album is
/// anchored on its *first* photo, so it keeps the place in the conversation
/// where the batch began and does not jump about as the rest of it arrives.
///
/// What breaks a run, and why:
///
///   * anything that is not a plain photo — a word between two pictures means
///     they were sent about different things;
///   * the other person — two people posting photos at once are not collaborating
///     on one album;
///   * a view-once photo, which is deliberately never drawn as a thumbnail and
///     has no business inside a grid of them;
///   * more than [kAlbumWindow] of silence, or [kMaxAlbumPhotos] already in
///     hand.
PhotoAlbums groupPhotoAlbums(List<Message> messages) {
  if (messages.length < 2) return const PhotoAlbums.empty();

  final byAnchor = <String, List<Message>>{};
  final folded = <String>{};
  var run = <Message>[];

  void flush() {
    if (run.length >= 2) {
      byAnchor[run.first.id] = List.unmodifiable(run);
      for (final message in run.skip(1)) {
        folded.add(message.id);
      }
    }
    run = <Message>[];
  }

  for (final message in messages) {
    if (!_albumable(message)) {
      flush();
      continue;
    }
    if (run.isNotEmpty && !_joins(run.last, message, run.length)) flush();
    run.add(message);
  }
  flush();

  if (byAnchor.isEmpty) return const PhotoAlbums.empty();
  return PhotoAlbums._(byAnchor, folded);
}

bool _albumable(Message message) =>
    message.kind == MessageKind.image &&
    !message.viewOnce &&
    message.imagePath != null;

bool _joins(Message previous, Message next, int soFar) {
  if (soFar >= kMaxAlbumPhotos) return false;
  if (previous.isMine != next.isMine) return false;
  // Channels put several authors in one bucket, so "the same sender" is a real
  // question there and `isMine` is not enough to answer it.
  if (previous.authorId != next.authorId) return false;
  final gap = next.sentAt.difference(previous.sentAt).abs();
  return gap <= kAlbumWindow;
}
