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
  });
}
