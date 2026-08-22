import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chats/presentation/chats_list_screen.dart';
import 'package:flutter_test/flutter_test.dart';

Message _msg({required bool mine, required DateTime at}) => Message(
      id: 'm${at.microsecondsSinceEpoch}${mine ? 'x' : 'y'}',
      chatId: 'peer',
      text: 'hi',
      sentAt: at,
      isMine: mine,
    );

void main() {
  final t0 = DateTime(2026, 1, 1, 12, 0, 0);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  group('unreadMessageCount', () {
    test('no marker → every inbound message is unread', () {
      final msgs = [
        _msg(mine: false, at: at(1)),
        _msg(mine: true, at: at(2)), // ours never counts
        _msg(mine: false, at: at(3)),
      ];
      expect(unreadMessageCount(msgs, null), 2);
    });

    test('only inbound messages after the marker count', () {
      final msgs = [
        _msg(mine: false, at: at(1)),
        _msg(mine: false, at: at(2)),
        _msg(mine: false, at: at(3)),
      ];
      expect(unreadMessageCount(msgs, at(2)), 1); // only the at(3) one
    });

    test('our own messages after the marker are ignored', () {
      final msgs = [
        _msg(mine: false, at: at(1)),
        _msg(mine: true, at: at(5)),
        _msg(mine: true, at: at(6)),
      ];
      expect(unreadMessageCount(msgs, at(2)), 0);
    });

    test('marker at or after the last message → nothing unread', () {
      final msgs = [
        _msg(mine: false, at: at(1)),
        _msg(mine: false, at: at(2)),
      ];
      expect(unreadMessageCount(msgs, at(2)), 0);
      expect(unreadMessageCount(msgs, at(10)), 0);
    });

    test('empty chat is never unread', () {
      expect(unreadMessageCount(const [], null), 0);
      expect(unreadMessageCount(const [], DateTime(2026)), 0);
    });

    /// The answer is cached against the list instance, because the chats list
    /// recomputes on every keystroke and nothing about an untouched
    /// conversation can have changed. These pin the two ways that could go
    /// wrong: an answer that outlives the question, and a marker the cache
    /// ignores.
    group('caching', () {
      test('the same list asked twice gives the same answer', () {
        final msgs = [
          _msg(mine: false, at: at(1)),
          _msg(mine: false, at: at(2)),
        ];
        expect(unreadMessageCount(msgs, null), 2);
        expect(unreadMessageCount(msgs, null), 2);
      });

      test('moving the read marker on the same list re-counts', () {
        // Opening a chat moves the marker and does not touch the messages, so
        // the marker has to be part of the key rather than only the list.
        final msgs = [
          _msg(mine: false, at: at(1)),
          _msg(mine: false, at: at(2)),
          _msg(mine: false, at: at(3)),
        ];
        expect(unreadMessageCount(msgs, null), 3);
        expect(unreadMessageCount(msgs, at(1)), 2);
        expect(unreadMessageCount(msgs, at(2)), 1);
        expect(unreadMessageCount(msgs, at(3)), 0);
        // ...and back, which a cache keyed only on "last seen marker" would
        // get right by accident and one keyed on the list alone would not.
        expect(unreadMessageCount(msgs, null), 3);
      });

      test('an equal marker at a different instant is still the same key', () {
        final msgs = [_msg(mine: false, at: at(3))];
        expect(unreadMessageCount(msgs, at(1)), 1);
        expect(unreadMessageCount(msgs, DateTime(2026, 1, 1, 12, 0, 1)), 1);
      });

      test('a new list with a new message is counted again', () {
        // What MessagesController actually does: every write replaces the
        // list, so the cache never sees one grow underneath it.
        final first = [_msg(mine: false, at: at(1))];
        expect(unreadMessageCount(first, null), 1);

        final second = [...first, _msg(mine: false, at: at(2))];
        expect(unreadMessageCount(second, null), 2);
        // The old instance still answers for itself.
        expect(unreadMessageCount(first, null), 1);
      });
    });
  });
}
