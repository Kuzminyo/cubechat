import 'dart:typed_data';

import 'package:cubechat/features/call/domain/call_record.dart';
import 'package:cubechat/features/call/domain/call_state_machine.dart';
import 'package:cubechat/features/call/domain/recent_calls.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

/// The calls list in Contacts, gathered out of the records every call already
/// leaves in its conversation.
void main() {
  final alice = 'a' * 64;
  final bob = 'b' * 64;

  Message call(
    String chat,
    DateTime at, {
    required bool outgoing,
    int talked = 0,
  }) =>
      Message(
        id: 'call-${at.microsecondsSinceEpoch}',
        chatId: chat,
        text: encodeCallRecord(
          CallOutcome(
            callId: Uint8List(16),
            outgoing: outgoing,
            cause: talked > 0 ? CallEndCause.hungUp : CallEndCause.noAnswer,
            talkedFor: Duration(seconds: talked),
            source: CallEndSource.button,
          ),
        ),
        sentAt: at,
        isMine: outgoing,
      );

  final noon = DateTime(2026, 9, 14, 12);

  test('newest first, across every conversation, and nothing but calls', () {
    final calls = recentCalls({
      alice: [
        call(alice, noon, outgoing: true, talked: 65),
        Message(id: 'm', chatId: alice, text: 'hi', sentAt: noon, isMine: true),
      ],
      bob: [call(bob, noon.add(const Duration(hours: 1)), outgoing: false)],
    });
    expect(calls.map((c) => c.peerId), [bob, alice]);
    expect(calls.first.kind, RecentCallKind.missed);
    expect(calls.last.kind, RecentCallKind.outgoing);
    expect(calls.last.talkedFor, const Duration(seconds: 65));
  });

  test('a run of the same call to the same person on one day is one line', () {
    final calls = recentCalls({
      bob: [
        call(bob, noon, outgoing: false),
        call(bob, noon.add(const Duration(minutes: 2)), outgoing: false),
        call(bob, noon.add(const Duration(minutes: 4)), outgoing: false),
      ],
    });
    expect(calls, hasLength(1));
    expect(calls.single.count, 3);
    expect(calls.single.at, noon.add(const Duration(minutes: 4)));
  });

  test('missed only leaves out the answered and our own unanswered', () {
    final calls = recentCalls({
      alice: [
        call(alice, noon, outgoing: true),
        call(alice, noon.add(const Duration(hours: 1)), outgoing: false,
            talked: 10),
      ],
      bob: [call(bob, noon.add(const Duration(hours: 2)), outgoing: false)],
    }, missedOnly: true);
    expect(calls.map((c) => c.peerId), [bob]);
  });

  test('channels and the notebook are not looked in', () {
    final calls = recentCalls({
      '#general': [call('#general', noon, outgoing: false)],
    });
    expect(calls, isEmpty);
  });
}
