import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chats/domain/message_hits.dart';
import 'package:cubechat/features/chats/models/chat.dart';
import 'package:flutter_test/flutter_test.dart';

Chat _chat(String id, {String? name, bool isChannel = false}) => Chat(
      id: id,
      peerId: id,
      peerName: name ?? id,
      lastMessage: '',
      lastTime: DateTime(2026),
      unreadCount: 0,
      isMesh: false,
      isOnline: false,
      isChannel: isChannel,
    );

Message _message(String id, String text, {DateTime? at}) => Message(
      id: id,
      chatId: 'chat',
      text: text,
      sentAt: at ?? DateTime(2026),
      isMine: false,
    );

void main() {
  group('searching every conversation at once', () {
    test('finds the words wherever they were said', () {
      final hits = messageHits(
        chats: [_chat('anna'), _chat('#team', isChannel: true)],
        messagesByChat: {
          'anna': [_message('a1', 'take the keys from the table')],
          '#team': [
            _message('t1', 'nothing to do with it'),
            _message('t2', 'the keys are with me'),
          ],
        },
        query: 'keys',
      );

      expect(hits.map((h) => h.message.id), containsAll(['a1', 't2']));
      expect(hits.length, 2, reason: 'and nothing else');
    });

    test('newest first, across conversations', () {
      final hits = messageHits(
        chats: [_chat('a'), _chat('b')],
        messagesByChat: {
          'a': [_message('old', 'report', at: DateTime(2026, 1))],
          'b': [_message('new', 'report', at: DateTime(2026, 8))],
        },
        query: 'report',
      );

      expect(hits.map((h) => h.message.id), ['new', 'old']);
    });

    test('carries the conversation each hit was found in', () {
      final hits = messageHits(
        chats: [_chat('anna', name: 'Ганна')],
        messagesByChat: {
          'anna': [_message('a1', 'домовились')],
        },
        query: 'домовились',
      );

      expect(hits.single.chat.peerName, 'Ганна');
    });

    test('a one-letter query does not sweep the archive', () {
      final hits = messageHits(
        chats: [_chat('a')],
        messagesByChat: {
          'a': [_message('a1', 'anything')],
        },
        query: 'a',
      );

      expect(hits, isEmpty, reason: 'the name search still answers it');
    });

    test('the cap holds, and holds the newest end', () {
      final many = List.generate(
        200,
        (i) => _message('m$i', 'report', at: DateTime(2026, 1, 1, 0, i)),
      );

      final hits = messageHits(
        chats: [_chat('a')],
        messagesByChat: {'a': many},
        query: 'report',
        limit: 10,
      );

      expect(hits.length, 10);
      expect(hits.first.message.id, 'm199');
    });
  });

  group('the snippet shows the part that matched', () {
    test('a short message is shown whole', () {
      final snippet = messageHitSnippet(_message('m', 'the keys'), 'keys');
      expect(snippet.text, 'the keys');
      expect(snippet.text.substring(
        snippet.marks.single.start,
        snippet.marks.single.end,
      ), 'keys');
    });

    test('a long message is cut around the match, not at its start', () {
      final text = '${'padding words ' * 30}needle at the end';
      final snippet = messageHitSnippet(_message('m', text), 'needle');

      expect(snippet.text, contains('needle'));
      expect(snippet.text.length, lessThan(text.length));
      expect(snippet.text, startsWith('...'));
      expect(
        snippet.text.substring(
          snippet.marks.single.start,
          snippet.marks.single.end,
        ),
        'needle',
        reason: 'the marks moved with the cut',
      );
    });
  });
}
