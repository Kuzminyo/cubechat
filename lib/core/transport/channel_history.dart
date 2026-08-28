import 'dart:convert';
import 'dart:typed_data';

/// A room's backlog, handed over in one signed frame.
///
/// Joining a channel is deriving a key from a name, which tells you nothing
/// about what was said before you arrived — so a new member lands in an empty
/// room that everybody else has been talking in for a week. There is no server
/// holding the history and no way to ask one for it; the only copies are on the
/// phones already in the room, and this is one of them offering theirs.
///
/// Wire layout:
///
/// ```
///   [version : 1 byte = 0x01]
///   [count   : 1 byte — posts that follow, 1..maxPosts]
///   count x:
///     [wireId  : 16 bytes — the transport msgId hash the original travelled
///                           under, which is what makes this idempotent]
///     [sentAtS :  5 bytes big-endian — unix seconds]
///     [textLen :  2 bytes big-endian]
///     [text    : textLen bytes UTF-8]
/// ```
///
/// **The wireId is the whole point.** Message insertion is already idempotent
/// on it, so a backlog broadcast into a room lands only where a post is
/// missing: everybody who was already there receives it and stores nothing,
/// and the person who just joined gets the week they missed. Re-sending the
/// posts as ordinary messages could not do that — each send mints a fresh
/// msgId, so every member would see the room's whole history a second time.
///
/// **Only an administrator's copy is worth taking, and only in a room where
/// only administrators post.** A channel frame is signed by whoever sent it,
/// so a backlog carries the *forwarder's* signature over somebody else's
/// words. In an announcement channel that is nobody else's words — the admin
/// wrote all of them — and the signature says exactly what it should. In an
/// open group it would be a licence to put sentences in other people's mouths,
/// which is why the receiving side refuses one there.
class ChannelHistory {
  const ChannelHistory({required this.posts});

  static const int version1 = 0x01;
  static const int wireIdLen = 16;
  static const int _sentAtLen = 5;

  /// Enough to make a room worth entering, bounded so one tap cannot put a
  /// megabyte of somebody's history on the air. A frame this size is
  /// fragmented and reassembled like any other; the cap is about airtime and
  /// about the 255 fragments the header can count, not about the format.
  static const int maxPosts = 50;

  /// Longest single post carried. A photo is not in here at all — this is text
  /// only, because the pictures are chunked streams with their own manifests
  /// and replaying those is a different job.
  static const int maxTextBytes = 2000;

  final List<ChannelHistoryPost> posts;

  Uint8List encode() {
    if (posts.isEmpty || posts.length > maxPosts) {
      throw FormatException('channel history holds 1..$maxPosts posts');
    }
    final chunks = <List<int>>[];
    var total = 2;
    for (final post in posts) {
      if (post.wireId.length != wireIdLen) {
        throw const FormatException('history wireId must be 16 bytes');
      }
      final text = utf8.encode(post.text);
      if (text.length > maxTextBytes) {
        throw FormatException('history post is ${text.length} B, '
            'max $maxTextBytes');
      }
      final seconds = post.sentAt.millisecondsSinceEpoch ~/ 1000;
      if (seconds < 0 || seconds > 0xFFFFFFFFFF) {
        throw const FormatException('history timestamp out of range');
      }
      final row = <int>[
        ...post.wireId,
        for (var i = _sentAtLen - 1; i >= 0; i--) (seconds >> (8 * i)) & 0xFF,
        (text.length >> 8) & 0xFF,
        text.length & 0xFF,
        ...text,
      ];
      chunks.add(row);
      total += row.length;
    }
    final out = Uint8List(total);
    out[0] = version1;
    out[1] = posts.length;
    var cursor = 2;
    for (final row in chunks) {
      out.setRange(cursor, cursor += row.length, row);
    }
    return out;
  }

  static ChannelHistory decode(Uint8List bytes) {
    if (bytes.length < 2) {
      throw const FormatException('channel history truncated');
    }
    if (bytes[0] != version1) {
      throw FormatException('channel history version ${bytes[0]} unsupported');
    }
    final count = bytes[1];
    if (count == 0 || count > maxPosts) {
      throw FormatException('channel history claims $count posts');
    }
    final posts = <ChannelHistoryPost>[];
    var cursor = 2;
    for (var i = 0; i < count; i++) {
      // Every read is bounds-checked before it happens: this decodes a frame
      // from the air, and a length field is the first thing an attacker
      // reaches for.
      if (cursor + wireIdLen + _sentAtLen + 2 > bytes.length) {
        throw const FormatException('channel history post truncated');
      }
      final wireId = Uint8List.fromList(
        bytes.sublist(cursor, cursor + wireIdLen),
      );
      cursor += wireIdLen;
      var seconds = 0;
      for (var b = 0; b < _sentAtLen; b++) {
        seconds = (seconds << 8) | bytes[cursor + b];
      }
      cursor += _sentAtLen;
      final textLen = (bytes[cursor] << 8) | bytes[cursor + 1];
      cursor += 2;
      if (textLen > maxTextBytes || cursor + textLen > bytes.length) {
        throw const FormatException('channel history text out of range');
      }
      posts.add(
        ChannelHistoryPost(
          wireId: wireId,
          sentAt: DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
          text: utf8.decode(
            bytes.sublist(cursor, cursor + textLen),
            allowMalformed: true,
          ),
        ),
      );
      cursor += textLen;
    }
    if (cursor != bytes.length) {
      throw const FormatException('channel history has trailing bytes');
    }
    return ChannelHistory(posts: posts);
  }
}

/// One post out of a room's backlog.
class ChannelHistoryPost {
  const ChannelHistoryPost({
    required this.wireId,
    required this.sentAt,
    required this.text,
  });

  /// The transport msgId hash the post originally travelled under. What makes
  /// re-delivery harmless.
  final Uint8List wireId;

  final DateTime sentAt;
  final String text;
}
