import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/map/data/map_friend_link.dart';
import 'package:cubechat/features/map/data/map_friends_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Message text(String body, {bool isMine = false}) => Message(
        id: 'm',
        chatId: 'peer',
        text: body,
        sentAt: DateTime(2026, 8, 11, 12),
        isMine: isMine,
      );

  final invite = MapFriendLink.invite(displayName: 'Kuz').encode();
  final accepted = MapFriendLink.accepted(displayName: 'Roma').encode();

  group('chatIsMapFriend', () {
    test('an invitation we sent is enough on its own', () {
      // The half that was missing. The invitee accepted and had us on their map
      // at once; our side waited for their acceptance to arrive, and when it
      // did not, the pairing had to be redone from the other direction.
      expect(chatIsMapFriend([text(invite, isMine: true)]), isTrue);
    });

    test('an acceptance counts from either side', () {
      expect(chatIsMapFriend([text(invite, isMine: true), text(accepted)]), isTrue);
      expect(chatIsMapFriend([text(accepted, isMine: true)]), isTrue);
    });

    test('being invited is not an answer', () {
      // Their invitation, unanswered. Sharing a position has to stay the
      // invitee's decision — this is the one case that must not auto-pair.
      expect(chatIsMapFriend([text(invite)]), isFalse);
    });

    test('ordinary conversation says nothing', () {
      expect(chatIsMapFriend([text('hey'), text('on my way', isMine: true)]), isFalse);
      expect(chatIsMapFriend(const []), isFalse);
    });
  });

  group('the link itself', () {
    test('points at our own domain, with the payload in the fragment', () {
      // cubechat.app is a domain nobody here holds; see MapFriendLink._prefix.
      expect(invite, startsWith('https://cubechat.tech/map#'));
      expect(invite, isNot(contains('cubechat.app')));
      final parsed = MapFriendLink.tryParse(invite)!;
      expect(parsed.kind, MapFriendLinkKind.invite);
      expect(parsed.displayName, 'Kuz');
    });

    test('an invitation from an older build still reads', () {
      final legacy = invite.replaceFirst(
        'https://cubechat.tech/map#',
        'https://cubechat.app/map/',
      );
      final parsed = MapFriendLink.tryParse(legacy)!;
      expect(parsed.kind, MapFriendLinkKind.invite);
      expect(chatIsMapFriend([text(legacy, isMine: true)]), isTrue);
    });

    test('the same payload under any other host is not a map link', () {
      final foreign = invite.replaceFirst('cubechat.tech', 'cubechat.example');
      expect(MapFriendLink.tryParse(foreign), isNull);
    });
  });
}
