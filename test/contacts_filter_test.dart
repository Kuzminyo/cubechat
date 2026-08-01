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

  test('contact opens its profile before the chat', () {
    final route = routeForContactProfile(_chat('ab cd', 'Alice & Bob'));

    expect(route, '/person/ab%20cd?name=Alice+%26+Bob');
  });
}
