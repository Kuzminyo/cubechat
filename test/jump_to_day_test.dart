import 'package:cubechat/core/utils/time_format.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

Message _at(String id, DateTime when) => Message(
      id: id,
      chatId: 'chat',
      text: id,
      sentAt: when,
      isMine: false,
    );

/// The same search the chat screen runs when the floating date is tapped: the
/// first message of the day, in conversation order.
Message? _firstOfDay(List<Message> messages, DateTime day) {
  final index = messages.indexWhere((m) => !startsNewDay(m.sentAt, day));
  return index < 0 ? null : messages[index];
}

void main() {
  final messages = [
    _at('mon-1', DateTime(2026, 8, 10, 9)),
    _at('mon-2', DateTime(2026, 8, 10, 18)),
    _at('tue-1', DateTime(2026, 8, 11, 8)),
    _at('tue-2', DateTime(2026, 8, 11, 12)),
    _at('tue-3', DateTime(2026, 8, 11, 23, 59)),
    _at('thu-1', DateTime(2026, 8, 13, 7)),
  ];

  test('a day lands on its first message, not its nearest', () {
    // The whole point of tapping a date: "take me to where this day starts".
    // Landing in the middle leaves the reader scrolling up for the beginning
    // they just asked for.
    expect(_firstOfDay(messages, DateTime(2026, 8, 11, 20))?.id, 'tue-1');
  });

  test('the time of day in the request is ignored', () {
    // The chip names a day; the hour it happens to carry is whichever message
    // was under the header when it was tapped.
    for (final hour in [0, 8, 12, 23]) {
      expect(
        _firstOfDay(messages, DateTime(2026, 8, 11, hour, 30))?.id,
        'tue-1',
      );
    }
  });

  test('the first day of the conversation works too', () {
    expect(_firstOfDay(messages, DateTime(2026, 8, 10, 12))?.id, 'mon-1');
  });

  test('a day with nothing in it answers with nothing', () {
    // 12 August is a gap in this conversation. Better to do nothing than to
    // scroll somewhere the user did not name.
    expect(_firstOfDay(messages, DateTime(2026, 8, 12)), isNull);
  });

  test('a day either side of the conversation answers with nothing', () {
    expect(_firstOfDay(messages, DateTime(2026, 8, 1)), isNull);
    expect(_firstOfDay(messages, DateTime(2026, 9, 1)), isNull);
  });
}
