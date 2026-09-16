import 'dart:typed_data';

import 'package:cubechat/core/transport/messaging_service.dart';
import 'package:cubechat/features/channels/data/channel_roster_controller.dart';
import 'package:cubechat/features/peers/models/known_peer.dart';
import 'package:flutter_test/flutter_test.dart';

KnownPeer _peer(String id, {Uint8List? signKey}) => KnownPeer(
      pubkeyHex: id,
      displayName: id,
      lastSeen: DateTime(2026, 9, 15),
      signPublicKey: signKey,
    );

ChannelMember _member(Uint8List signKey, {bool removed = false}) =>
    ChannelMember(
      id: ChannelRosterController.fingerprintOf(signKey),
      name: 'member',
      isAdmin: false,
      lastSeen: DateTime(2026, 9, 15),
      removedAt: removed ? DateTime(2026, 9, 14) : null,
    );

/// Who a room post wakes.
///
/// Every room frame used to ring every contact it went to — members or not —
/// so people with no message to read, most of them not in the room, got
/// "Нове повідомлення" for receipts, reactions and the chunks of a photo.
void main() {
  final inRoom = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
  final outsider = Uint8List.fromList(List<int>.generate(32, (i) => 200 - i));
  final putOut = Uint8List.fromList(List<int>.generate(32, (i) => i * 3));

  final roster = {
    'a': _member(inRoom),
    'b': _member(putOut, removed: true),
  };

  test('a member of the room is woken', () {
    final ids = roomMemberIds(roster);
    expect(isRoomMember(_peer('in', signKey: inRoom), ids), isTrue);
  });

  test('a contact who is not in the room is not', () {
    final ids = roomMemberIds(roster);
    expect(isRoomMember(_peer('out', signKey: outsider), ids), isFalse);
  });

  test('nor is somebody put out of it, nor a contact with no signing key', () {
    final ids = roomMemberIds(roster);
    expect(isRoomMember(_peer('removed', signKey: putOut), ids), isFalse);
    expect(isRoomMember(_peer('unsigned'), ids), isFalse);
  });

  group('who the chunks of a room transfer go to', () {
    // One 389 KB picture went out as seven chunks to eleven contacts on eight
    // relays — 704 publishes, most of them to people who could not open a
    // chunk and do not carry one onward — and the log came back full of
    // `rate limited` and `event too large`.
    final member = _peer('in', signKey: inRoom);
    final stranger = _peer('out', signKey: outsider);
    final peers = [member, stranger];

    test('a picture: only the members', () {
      expect(
        roomRelayAudience(peers, members: roomMemberIds(roster), mediaLane: true),
        [member],
      );
    });

    test('a post: everybody, so a member nobody has heard from still gets it',
        () {
      expect(
        roomRelayAudience(peers,
            members: roomMemberIds(roster), mediaLane: false),
        peers,
      );
    });

    test('a picture with no roster: everybody, because the roster is what is '
        'wrong', () {
      expect(
        roomRelayAudience(peers, members: const <String>{}, mediaLane: true),
        peers,
      );
    });
  });

  test('a room nobody knows the members of wakes nobody', () {
    expect(roomMemberIds(null), isEmpty);
    expect(isRoomMember(_peer('in', signKey: inRoom), roomMemberIds(null)),
        isFalse);
  });
}
