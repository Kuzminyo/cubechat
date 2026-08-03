import 'package:cubechat/core/transport/channel_admin.dart';
import 'package:cubechat/core/transport/channel_poll.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('channel poll create payload round-trips and trims input', () {
    final decoded = ChannelPollPayload.decode(
      ChannelPollPayload.create('  Where? ', [' Home ', 'Park']).encode(),
    );

    expect(decoded.operation, ChannelPollOperation.create);
    expect(decoded.question, 'Where?');
    expect(decoded.options, ['Home', 'Park']);
  });

  test('channel poll vote payload identifies message and option', () {
    final wireId = 'ab' * 16;
    final decoded = ChannelPollPayload.decode(
      ChannelPollPayload.vote(wireId, 2).encode(),
    );

    expect(decoded.operation, ChannelPollOperation.vote);
    expect(decoded.targetWireId, wireId);
    expect(decoded.option, 2);
  });

  test('invalid polls and votes are rejected', () {
    expect(
        () => ChannelPollPayload.create('', ['a', 'b']), throwsFormatException);
    expect(() => ChannelPollPayload.create('Question', ['one']),
        throwsFormatException);
    expect(() => ChannelPollPayload.vote('bad', 0), throwsFormatException);
  });

  test('administrator changes round-trip signed member fingerprint', () {
    const change = ChannelAdminChange(
      memberId: '0123456789abcdef',
      isAdmin: true,
    );
    final decoded = ChannelAdminChange.decode(change.encode());

    expect(decoded.memberId, change.memberId);
    expect(decoded.isAdmin, isTrue);
    expect(() => ChannelAdminChange.decode(change.encode().sublist(1)),
        throwsFormatException);
  });
}
