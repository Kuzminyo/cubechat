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

  test('deleting the conversation does not delete the contact', () {
    final result = contactChatsFromHistory(
      [_chat('bob', 'Bob'), _chat('nearby-only', 'Nearby only')],
      // Deleting the chat wipes its history, so Bob is in neither the message
      // store nor — before this — the contacts list.
      const <String>{},
      deletedChatIds: const {'bob'},
    );

    expect(result.map((chat) => chat.id), ['bob']);
  });

  test('removing a contact takes them off this screen and nowhere else', () {
    // The other half of the pair above. Deleting a conversation must not
    // delete the contact; removing a contact must not delete the conversation
    // — which means the history that builds this row is still there, and only
    // this list may act on the removal.
    final result = contactChatsFromHistory(
      [_chat('bob', 'Bob'), _chat('carol', 'Carol')],
      const {'bob', 'carol'},
      removedContactIds: const {'bob'},
    );

    expect(result.map((chat) => chat.id), ['carol']);
  });

  test('a removed contact stays off even with the chat deleted too', () {
    // Both kinds of evidence present at once: history and a deleted
    // conversation. Neither may put somebody back.
    final result = contactChatsFromHistory(
      [_chat('bob', 'Bob')],
      const {'bob'},
      deletedChatIds: const {'bob'},
      removedContactIds: const {'bob'},
    );

    expect(result, isEmpty);
  });

  test('contact opens its profile before the chat', () {
    final route = routeForContactProfile(_chat('ab cd', 'Alice & Bob'));

    expect(route, '/person/ab%20cd?name=Alice+%26+Bob');
  });
}
