import 'package:cubechat/features/chat/domain/unread_divider.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where "New messages" goes: above the first message that arrived after the
/// chat was last read — by the same rule as the unread badge in the list, so
/// the line and the number never disagree.
void main() {
  Message msg(String id, int minute, {bool mine = false}) => Message(
        id: id,
        chatId: 'c',
        text: id,
        sentAt: DateTime(2026, 9, 30, 12, minute),
        isMine: mine,
      );

  final history = [
    msg('a', 1),
    msg('b', 2, mine: true),
    msg('c', 3),
    msg('d', 4, mine: true),
    msg('e', 5),
    msg('f', 6),
  ];

  test('the first of theirs after the marker', () {
    expect(firstUnreadMessageId(history, DateTime(2026, 9, 30, 12, 3)), 'e');
  });

  test('my own messages are never the unread line', () {
    // After the marker only my message and then theirs: the line goes above
    // theirs, not above what I wrote.
    expect(firstUnreadMessageId(history, DateTime(2026, 9, 30, 12, 3, 30)),
        'e');
  });

  test('nothing new, or never opened: no line', () {
    expect(firstUnreadMessageId(history, DateTime(2026, 9, 30, 12, 6)), isNull);
    // A chat never opened has no "since"; a line above the whole history says
    // nothing.
    expect(firstUnreadMessageId(history, null), isNull);
    expect(firstUnreadMessageId(const [], DateTime(2026)), isNull);
  });
}
