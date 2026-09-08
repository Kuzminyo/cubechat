import 'dart:io';

import 'package:cubechat/features/chat/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

/// Which message the read marker is set from when a chat is opened.
///
/// It was `history.last.sentAt` — the last message to **arrive**. Since 956 a
/// message carries the sender's clock rather than the moment it landed, so a
/// batch delivered out of order (every relay backlog, every burst spread over
/// three relays) routinely ends on a message stamped earlier than one already
/// in the list.
///
/// The marker never moves backwards, by design. Set from the wrong end it
/// sticks below its own conversation, and everything above it reads as unread
/// for ever: "закрытое приложение, приходит два уведа, открывается чат,
/// прочиталось два, остальное висит непрочитанным, помогает только позначити
/// як прочитано". That button works precisely because it passes no timestamp
/// and gets `now()`.
///
/// The sweep said so once it was asked to: `nothing to ack … 4 not read yet`,
/// eight times in forty seconds, the same four each time.
Message _at(String id, DateTime sentAt) => Message(
      id: id,
      chatId: 'peer',
      text: id,
      sentAt: sentAt,
      isMine: false,
    );

void main() {
  final t0 = DateTime(2026, 9, 8, 14, 48);

  test('an empty history has no newest', () {
    expect(newestSentAt(const <Message>[]), isNull);
  });

  test('in order, it is the last one', () {
    expect(
      newestSentAt([
        _at('a', t0),
        _at('b', t0.add(const Duration(seconds: 1))),
        _at('c', t0.add(const Duration(seconds: 2))),
      ]),
      t0.add(const Duration(seconds: 2)),
    );
  });

  test('out of order, it is still the latest — which is the whole bug', () {
    // Arrival order c, a, b. `history.last` is b, and a message stamped after
    // b would then sit above the marker for ever.
    final history = [
      _at('c', t0.add(const Duration(seconds: 9))),
      _at('a', t0),
      _at('b', t0.add(const Duration(seconds: 3))),
    ];
    expect(newestSentAt(history), t0.add(const Duration(seconds: 9)));
    expect(
      newestSentAt(history),
      isNot(history.last.sentAt),
      reason: 'if these were equal the test would prove nothing',
    );
  });

  test('a single message is its own newest', () {
    expect(newestSentAt([_at('a', t0)]), t0);
  });

  test('identical stamps do not confuse it', () {
    // A burst can share a millisecond; nothing here should care.
    expect(newestSentAt([_at('a', t0), _at('b', t0)]), t0);
  });

  test('the chat screen asks for the latest, not the last', () {
    // Pinned in the file that opens the chat, because reverting to `.last`
    // would compile, pass every other test, and quietly restore the report.
    final source =
        File('lib/features/chat/presentation/chat_screen.dart').readAsStringSync();
    expect(source, contains('newestSentAt(history)'));
    expect(
      source,
      isNot(contains('history.last.sentAt')),
      reason: 'the last to arrive is not the latest to have been sent',
    );
  });
}
