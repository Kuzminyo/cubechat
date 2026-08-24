import 'package:cubechat/features/chat/domain/message_search.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

Message _message({
  required String id,
  required String text,
  String? authorName,
}) =>
    Message(
      id: id,
      chatId: 'chat',
      text: text,
      sentAt: DateTime(2026),
      isMine: false,
      authorName: authorName,
    );

/// The substrings a highlight would actually paint, which is the only form in
/// which an offset bug is legible.
List<String> _painted(String text, String query) => messageHighlightRanges(
      text,
      query,
    ).map((range) => text.substring(range.start, range.end)).toList();

void main() {
  group('a name no longer drags its whole conversation in', () {
    test('a query inside a name matches nothing it is not in', () {
      final messages = [
        _message(id: 'hers', text: 'добре, буду о шостій', authorName: 'Ганна'),
        _message(id: 'his', text: 'ану подивимось', authorName: 'Петро'),
      ];

      // "ан" sits inside "Ганна". It used to return her line, which does not
      // contain those letters — the report, exactly.
      expect(
        messagesMatchingQuery(messages, 'ан').map((m) => m.id),
        ['his'],
        reason: 'only the message whose text holds the query',
      );
    });

    test('a name still answers when the query starts one of its words', () {
      final messages = [
        _message(id: 'author', text: 'ok', authorName: 'Kuzminyo'),
        _message(id: 'plain', text: 'nothing here'),
      ];

      expect(messagesMatchingQuery(messages, 'kuz').single.id, 'author');
      expect(messagesMatchingQuery(messages, 'kuzminyo').single.id, 'author');
    });

    test('every word of the query has to land somewhere in the name', () {
      final messages = [
        _message(id: 'a', text: 'ok', authorName: 'Anna Kuzminyo'),
      ];

      expect(messagesMatchingQuery(messages, 'anna kuz').single.id, 'a');
      expect(messagesMatchingQuery(messages, 'anna petro'), isEmpty);
    });
  });

  group('the highlight lands on the letters that matched', () {
    test('offsets survive the folding of cyrillic variants', () {
      // Folded, "Привіт" and the query are the same word; raw, they are not.
      // An offset taken from the folded copy pointed at the wrong letters.
      expect(_painted('Привіт, Семён!', 'привит'), ['Привіт']);
      expect(_painted('Привіт, Семён!', 'семен'), ['Семён']);
    });

    test('offsets survive collapsed whitespace', () {
      // Every run of spaces the fold swallows shifts a naive offset further
      // left. Three runs before the word is enough to land on the wrong one.
      const text = 'one   two    three     target';
      expect(_painted(text, 'target'), ['target']);
    });

    test('every occurrence is marked, not just the first', () {
      expect(_painted('hello there hello', 'hello'), ['hello', 'hello']);
    });

    test('a multi-word query marks each word where it sits', () {
      expect(
        _painted('the quick brown fox', 'fox quick'),
        ['quick', 'fox'],
        reason: 'in the order they appear, not the order they were typed',
      );
    });

    test('an emoji is framed whole rather than cut in half', () {
      // A surrogate pair is two code units; an end computed as start + 1
      // sliced it and rendered a broken glyph.
      final painted = _painted('пожежа 🔥 тут', '🔥');
      expect(painted, ['🔥']);
    });

    test('a match on the name alone paints nothing', () {
      // There is no honest thing to underline in a body the query is not in.
      expect(messageHighlightRanges('ok', 'kuz'), isEmpty);
    });

    test('an empty query paints nothing', () {
      expect(messageHighlightRanges('anything at all', '   '), isEmpty);
    });
  });
}
