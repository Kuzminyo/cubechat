import 'dart:typed_data';

import 'package:cubechat/core/transport/channel_admin.dart';
import 'package:cubechat/core/transport/channel_history.dart';
import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:flutter_test/flutter_test.dart';

/// Three payloads that all arrive from the air. Each one gets the round trip
/// and the tampering, which is the shape every decoder here is held to: a
/// decoder that trusts its input is a remote crash.
void main() {
  group('channel moderation', () {
    test('a removal survives the round trip', () {
      final wire = ChannelModeration(
        memberId: 'ab' * 8,
        action: ChannelModerationAction.remove,
      ).encode();

      final back = ChannelModeration.decode(wire);

      expect(back.memberId, 'ab' * 8);
      expect(back.action, ChannelModerationAction.remove);
      expect(back.until, isNull);
    });

    test('a mute carries its deadline to the second', () {
      // To the second, and no finer: the field holds seconds so that five
      // bytes reach past this century rather than stopping in 2004.
      final ms = DateTime.now().add(const Duration(hours: 8));
      final until = DateTime.fromMillisecondsSinceEpoch(
        (ms.millisecondsSinceEpoch ~/ 1000) * 1000,
      );

      final back = ChannelModeration.decode(
        ChannelModeration(
          memberId: '0f' * 8,
          action: ChannelModerationAction.mute,
          until: until,
        ).encode(),
      );

      expect(back.until?.millisecondsSinceEpoch, until.millisecondsSinceEpoch);
      expect(back.action, ChannelModerationAction.mute);
    });

    test('a member id that is not a fingerprint is refused', () {
      expect(
        () => ChannelModeration(
          memberId: 'not-hex',
          action: ChannelModerationAction.remove,
        ).encode(),
        throwsA(isA<FormatException>()),
      );
    });

    test('a short frame and an unknown action are both refused', () {
      expect(
        () => ChannelModeration.decode(Uint8List(13)),
        throwsA(isA<FormatException>()),
      );
      final wire = ChannelModeration(
        memberId: 'ab' * 8,
        action: ChannelModerationAction.remove,
      ).encode()
        ..[0] = 0x7F;
      expect(
        () => ChannelModeration.decode(wire),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('channel history', () {
    ChannelHistoryPost post(int n) => ChannelHistoryPost(
          wireId: Uint8List.fromList(List<int>.filled(16, n)),
          sentAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
          text: 'post $n',
        );

    test('a backlog survives the round trip', () {
      final back = ChannelHistory.decode(
        ChannelHistory(posts: [post(1), post(2), post(3)]).encode(),
      );

      expect(back.posts, hasLength(3));
      expect(back.posts[1].text, 'post 2');
      expect(back.posts[2].wireId.first, 3);
      // Seconds, not millis: the field is five bytes and the app shows a time,
      // not a stopwatch.
      expect(back.posts.first.sentAt.millisecondsSinceEpoch, 1700000000000);
    });

    test('an empty or oversized backlog is refused', () {
      expect(
        () => const ChannelHistory(posts: []).encode(),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ChannelHistory(
          posts: [
            for (var i = 0; i < ChannelHistory.maxPosts + 1; i++) post(1),
          ],
        ).encode(),
        throwsA(isA<FormatException>()),
      );
    });

    test('a count that outruns the bytes is refused, not read past', () {
      final wire = ChannelHistory(posts: [post(1)]).encode()..[1] = 9;
      expect(() => ChannelHistory.decode(wire), throwsA(isA<FormatException>()));
    });

    test('trailing bytes are refused', () {
      final wire = ChannelHistory(posts: [post(1)]).encode();
      final padded = Uint8List(wire.length + 1)..setRange(0, wire.length, wire);
      expect(
        () => ChannelHistory.decode(padded),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('forwarded-from', () {
    final target = Uint8List.fromList(List<int>.filled(16, 7));

    test('without a key it stays v1, which an old build still reads', () {
      final wire = ForwardedFrom(targetMsgId: target, name: 'Anna').encode();

      expect(wire.first, ForwardedFrom.version1);
      final back = ForwardedFrom.decode(wire);
      expect(back.name, 'Anna');
      expect(back.authorPub, isNull);
    });

    test('with a key it carries one back', () {
      final pub = Uint8List.fromList(List<int>.filled(32, 9));

      final back = ForwardedFrom.decode(
        ForwardedFrom(targetMsgId: target, name: 'Anna', authorPub: pub)
            .encode(),
      );

      expect(back.authorPub, pub);
      expect(back.name, 'Anna');
      expect(back.targetMsgId, target);
    });

    test('a v2 frame missing its key is refused', () {
      final wire = ForwardedFrom(
        targetMsgId: target,
        name: 'Anna',
        authorPub: Uint8List(32),
      ).encode();
      expect(
        () => ForwardedFrom.decode(wire.sublist(0, wire.length - 4)),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
