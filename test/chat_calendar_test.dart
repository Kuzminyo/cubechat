import 'dart:io';

import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/presentation/chat_calendar_screen.dart';
import 'package:flutter_test/flutter_test.dart';

Message _msg(String id, DateTime when, {String? photo}) => Message(
      id: id,
      chatId: 'chat',
      text: photo == null ? id : '',
      sentAt: when,
      isMine: false,
      kind: photo == null ? MessageKind.text : MessageKind.image,
      imagePath: photo,
    );

void main() {
  test('one entry per day that has something, oldest first', () {
    final days = conversationDays([
      _msg('a', DateTime(2026, 8, 11, 9)),
      _msg('b', DateTime(2026, 8, 10, 9)),
      _msg('c', DateTime(2026, 8, 11, 20)),
    ]);

    expect(days.map((d) => d.day), [
      DateTime(2026, 8, 10),
      DateTime(2026, 8, 11),
    ]);
    // A conversation is not a calendar: the gap between two days is not a row
    // of empty squares saying nothing.
    expect(days.length, 2);
  });

  test('the count is what was said that day', () {
    final days = conversationDays([
      _msg('a', DateTime(2026, 8, 11, 9)),
      _msg('b', DateTime(2026, 8, 11, 10)),
      _msg('c', DateTime(2026, 8, 12, 10)),
    ]);

    expect(days.first.count, 2);
    expect(days.last.count, 1);
  });

  test('a day with no photo has no photo', () {
    final days = conversationDays([_msg('a', DateTime(2026, 8, 11))]);
    expect(days.single.firstPhoto, isNull);
  });

  test('the square takes the first picture of the day that is still on disk',
      () async {
    final dir = await Directory.systemTemp.createTemp('cubechat-calendar');
    addTearDown(() => dir.delete(recursive: true));
    final present = File('${dir.path}/second.jpg')..writeAsBytesSync([1, 2, 3]);

    final days = conversationDays([
      // Sent first, but its file has been cleaned up since. Rendering it would
      // put an error box in the square, which reads as a broken calendar
      // rather than as a missing photo.
      _msg('gone', DateTime(2026, 8, 11, 9), photo: '${dir.path}/missing.jpg'),
      _msg('here', DateTime(2026, 8, 11, 10), photo: present.path),
    ]);

    expect(days.single.firstPhoto, present.path);
  });

  test('an empty conversation has no days', () {
    expect(conversationDays(const []), isEmpty);
  });
}
