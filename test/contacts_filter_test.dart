import 'package:cubechat/features/chats/models/chat.dart';
import 'package:cubechat/features/contacts/presentation/contacts_screen.dart';
import 'package:flutter_test/flutter_test.dart';

Chat _chat(String id, String name, {bool channel = false}) => Chat(
      id: id,
      peerId: id,
      peerName: name,
      lastMessage: 'hello',
      lastTime: DateTime(2026),
      unreadCount: 0,
      isMesh: true,
      isOnline: false,
      isChannel: channel,
    );

void main() {
  test('contacts contain only personal chats with message history', () {
    final result = contactChatsFromHistory(
      [
        _chat('bob', 'Bob'),
        _chat('alice', 'Alice'),
        _chat('nearby-only', 'Nearby only'),
        _chat('#team', '#team', channel: true),
      ],
      {'bob', 'alice', '#team'},
    );

    expect(result.map((chat) => chat.id), ['alice', 'bob']);
  });
}
