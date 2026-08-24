/// What a search may look inside, and where it landed.
///
/// This lived in `chat_screen.dart` while the conversation was the only thing
/// that could be searched. The chat list can now search message text across
/// every conversation at once, and a screen importing another screen to borrow
/// a pure function is the kind of dependency that makes both harder to move.
library;

import '../../../core/transport/shared_contact.dart';
import '../../../core/transport/shared_location.dart';
import '../../map/data/map_friend_link.dart';
import '../models/message.dart';

/// The words a search may look inside.
///
/// Not [Message.text], which is only words for a text message. A photo keeps
/// its mime type there, a voice note keeps `audio/aac`, a sticker keeps its
/// marker, and a shared contact or map pin keeps a base64 blob — so a search
/// for a single letter matched every photo in the conversation ("image/jpeg"
/// holds a, e, g, i, m) and every card ever swapped, and landed the reader on
/// a message the letter is plainly not in. That was the report, and it was
/// right: those strings are plumbing, not the message.
///
/// A sticker answers with the emoji it was filed under, which is the only name
/// it has and the only thing anybody could search it by.
String searchableMessageText(Message message) {
  if (message.isSticker) return message.stickerEmoji ?? '';
  final parts = <String>[
    switch (message.kind) {
      // The caption, never the mime type.
      MessageKind.image => message.imageCaption ?? '',
      MessageKind.text => _plainTextOrNothing(message.text),
      // The question is the message.
      MessageKind.poll => message.text,
      MessageKind.audio => '',
      MessageKind.file => '',
    },
    if (message.fileName != null) message.fileName!,
  ];
  return parts.where((part) => part.isNotEmpty).join(' ');
}

/// Text that is a payload rather than a sentence is not searchable either.
///
/// A contact card and a map pin travel as text — see [SharedContact] and
/// [MapFriendLink] — and what they carry is base64, which contains every
/// letter of the alphabet and belongs to none of them.
String _plainTextOrNothing(String text) {
  final trimmed = text.trim();
  if (trimmed.startsWith('cubechat:')) return '';
  if (SharedContact.tryParse(trimmed) != null) return '';
  if (MapFriendLink.tryParse(trimmed) != null) return '';
  if (SharedLocation.tryParse(trimmed) != null) return '';
  return text;
}

/// Whether the sender's name answers the query.
///
/// Deliberately stricter than the text match, and this is the second half of
/// the "it found messages the word is not in" report. In a channel it is
/// genuinely useful to search a person and get what they wrote, so the name
/// stays searchable — but as a plain substring it meant a query of "ан"
/// returned every line Ганна ever posted, none of which contain it, and the
/// reader is then staring at a highlighted nothing.
///
/// So a name answers only when the query starts one of its words. "kuz" still
/// finds Kuzminyo, "ганна" still finds Ганна, and "ан" no longer drags a whole
/// conversation in behind it.
bool _authorAnswers(String authorName, List<String> terms) {
  final words = _normalizeMessageSearchText(authorName)
      .split(' ')
      .where((word) => word.isNotEmpty)
      .toList(growable: false);
  if (words.isEmpty) return false;
  return terms.every(
    (term) => words.any((word) => word.startsWith(term)),
  );
}

/// The messages in [messages] that answer [query].
List<Message> messagesMatchingQuery(List<Message> messages, String query) {
  final needle = _normalizeMessageSearchText(query);
  if (needle.isEmpty) return const <Message>[];
  final terms = needle.split(' ').where((part) => part.isNotEmpty).toList();
  return messages.where((message) {
    final body = searchableMessageText(message);
    if (body.isNotEmpty) {
      final haystack = _normalizeMessageSearchText(body);
      if (haystack.isNotEmpty &&
          (haystack.contains(needle) ||
              terms.every((term) => haystack.contains(term)))) {
        return true;
      }
    }
    final author = message.authorName;
    return author != null && _authorAnswers(author, terms);
  }).toList(growable: false);
}

/// Where [query] lands inside [text], in offsets into [text] itself.
///
/// Highlighting cannot re-run the match on the raw string: the match is made
/// against a folded copy, where "Привіт" and "привит" are the same word and a
/// run of spaces is one space. Offsets from the folded copy point at the wrong
/// letters — usually a little to the left, and further with every space
/// collapsed. That is why the highlight sometimes framed the wrong half of a
/// word, or nothing at all.
///
/// So the fold records where each character came from, and the ranges are
/// mapped back through it. Returns disjoint ranges in order, empty when the
/// query does not appear as such — a message that matched on the author's name
/// has nothing to underline, and honestly says so rather than guessing.
List<({int start, int end})> messageHighlightRanges(String text, String query) {
  final needle = _normalizeMessageSearchText(query);
  if (needle.isEmpty || text.isEmpty) return const [];

  final (folded, starts, ends) = _foldWithSources(text);
  if (folded.isEmpty) return const [];

  // The whole phrase if it is there, otherwise each word on its own — the same
  // two chances the matcher gives, so what is highlighted is what matched.
  final targets = folded.contains(needle)
      ? [needle]
      : needle.split(' ').where((part) => part.isNotEmpty).toList();

  final ranges = <({int start, int end})>[];
  for (final target in targets) {
    var from = 0;
    while (from <= folded.length - target.length) {
      final at = folded.indexOf(target, from);
      if (at < 0) break;
      ranges.add((start: starts[at], end: ends[at + target.length - 1]));
      from = at + target.length;
    }
  }
  if (ranges.isEmpty) return const [];

  ranges.sort((a, b) => a.start.compareTo(b.start));
  // Words of a multi-word query can overlap once folding has collapsed the
  // space between them; two overlapping spans would paint the seam twice.
  final merged = <({int start, int end})>[ranges.first];
  for (final range in ranges.skip(1)) {
    final last = merged.last;
    if (range.start <= last.end) {
      if (range.end > last.end) {
        merged[merged.length - 1] = (start: last.start, end: range.end);
      }
    } else {
      merged.add(range);
    }
  }
  return merged;
}

/// The fold, plus where in the original string each folded character began and
/// ended. One pass, so the three can never drift apart.
///
/// Both ends are recorded rather than a start and a `+1`, because a character
/// is not always one code unit wide: an emoji is two, and a highlight that
/// assumed one cut it in half and rendered the broken surrogate.
(String, List<int>, List<int>) _foldWithSources(String value) {
  final buffer = StringBuffer();
  final starts = <int>[];
  final ends = <int>[];
  var previousWasSpace = true;
  var index = 0;
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    final width = char.length;
    final folded = _foldChar(char.toLowerCase());
    if (folded.trim().isEmpty) {
      if (!previousWasSpace) {
        buffer.write(' ');
        starts.add(index);
        ends.add(index + width);
      }
      previousWasSpace = true;
    } else {
      buffer.write(folded);
      // A fold may be longer than one code unit; every piece of it points at
      // the whole source character, so a match on any piece frames all of it.
      for (var i = 0; i < folded.length; i++) {
        starts.add(index);
        ends.add(index + width);
      }
      previousWasSpace = false;
    }
    index += width;
  }
  // Mirrors the trim in [_normalizeMessageSearchText]: a trailing space is
  // written before it is known to be trailing.
  var text = buffer.toString();
  if (text.endsWith(' ')) {
    text = text.substring(0, text.length - 1);
    starts.removeLast();
    ends.removeLast();
  }
  return (text, starts, ends);
}

String _foldChar(String char) => switch (char) {
      'ё' => 'е',
      'є' => 'е',
      'і' => 'и',
      'ї' => 'и',
      'ґ' => 'г',
      '’' || '`' || 'ʼ' => "'",
      _ => char,
    };

String _normalizeMessageSearchText(String value) {
  final lower = value.toLowerCase();
  final buffer = StringBuffer();
  var previousWasSpace = true;
  for (final rune in lower.runes) {
    final char = String.fromCharCode(rune);
    final normalized = _foldChar(char);
    if (normalized.trim().isEmpty) {
      if (!previousWasSpace) buffer.write(' ');
      previousWasSpace = true;
    } else {
      buffer.write(normalized);
      previousWasSpace = false;
    }
  }
  return buffer.toString().trim();
}
