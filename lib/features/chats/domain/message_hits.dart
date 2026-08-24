/// Searching the messages of every conversation at once.
///
/// The search screen could only ever match a chat's name, so finding a sentence
/// meant remembering who said it, opening that conversation and searching again
/// inside it — and if the memory was wrong, doing it a third time. The words are
/// the thing people remember; the name is what they are trying to recover.
library;

import '../../chat/domain/message_search.dart';
import '../../chat/models/message.dart';
import '../models/chat.dart';

/// One message, and the conversation it was found in.
typedef MessageHit = ({Chat chat, Message message});

/// How many hits are worth building rows for.
///
/// A scrollback of years answers a common word thousands of times, and nobody
/// reads past the first screen of an answer that long — they type another word.
/// The cap keeps the cost of a keystroke bounded by the cap rather than by how
/// long the user has had the app.
const int messageHitLimit = 60;

/// The shortest query worth sweeping every conversation for.
///
/// One letter matches almost everything, which is neither useful nor cheap;
/// the name search still runs on it, so a single letter is not a dead screen.
const int messageHitMinQuery = 2;

/// Every message across [chats] that answers [query], newest first.
///
/// Newest first because the search screen is a way back to something recent far
/// more often than it is an archive tour, and because a cap has to keep the end
/// people care about.
List<MessageHit> messageHits({
  required List<Chat> chats,
  required Map<String, List<Message>> messagesByChat,
  required String query,
  int limit = messageHitLimit,
}) {
  if (query.trim().length < messageHitMinQuery) return const [];

  final hits = <MessageHit>[];
  for (final chat in chats) {
    final messages = messagesByChat[chat.id];
    if (messages == null || messages.isEmpty) continue;
    for (final message in messagesMatchingQuery(messages, query)) {
      hits.add((chat: chat, message: message));
    }
  }
  hits.sort((a, b) => b.message.sentAt.compareTo(a.message.sentAt));
  return hits.length <= limit ? hits : hits.sublist(0, limit);
}

/// The line to show under the chat's name for [hit].
///
/// A message can be long and the match can be anywhere in it, so a plain
/// leading slice shows the first hundred characters of something whose match is
/// at character four hundred — a result that looks, to the reader, like a false
/// positive. This centres the window on the match instead.
///
/// Returns the snippet and where the query sits **inside the snippet**, ready
/// to highlight without re-running the fold.
({String text, List<({int start, int end})> marks}) messageHitSnippet(
  Message message,
  String query, {
  int window = 90,
}) {
  final full = searchableMessageText(message);
  if (full.isEmpty) return (text: '', marks: const []);

  final marks = messageHighlightRanges(full, query);
  if (full.length <= window || marks.isEmpty) {
    return (text: full, marks: marks);
  }

  // Start a little before the first match so it has some sentence in front of
  // it, and never past the point where the window would run off the end.
  const lead = 24;
  var from = marks.first.start - lead;
  if (from < 0) from = 0;
  if (from + window > full.length) from = full.length - window;
  final to = from + window;

  final ellipsis = from > 0 ? '...' : '';
  final shift = ellipsis.length - from;
  return (
    text: '$ellipsis${full.substring(from, to)}${to < full.length ? '...' : ''}',
    marks: marks
        .where((mark) => mark.start >= from && mark.end <= to)
        .map((mark) => (start: mark.start + shift, end: mark.end + shift))
        .toList(growable: false),
  );
}
