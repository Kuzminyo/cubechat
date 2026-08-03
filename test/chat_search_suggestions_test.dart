import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chats/models/chat.dart';
import 'package:cubechat/features/chats/presentation/chat_search_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the search screen offers before anything is typed.
///
/// The ordering is the whole feature — a row of faces in the wrong order is
/// worse than no row — and it is the kind of thing a later refactor can reorder
/// without anyone noticing.
void main() {
  Chat chat(String id, {bool favorite = false, bool channel = false}) => Chat(
        id: id,
        peerId: id,
        peerName: id,
        lastMessage: '',
        lastTime: DateTime(2026),
        unreadCount: 0,
        isMesh: false,
        isOnline: false,
        isFavorite: favorite,
        isChannel: channel,
      );

  Message msg(String chatId) => Message(
        id: 'm',
        chatId: chatId,
        text: 'x',
        sentAt: DateTime(2026),
        isMine: false,
      );

  Map<String, List<Message>> volumes(Map<String, int> counts) => {
        for (final e in counts.entries)
          e.key: List.generate(e.value, (_) => msg(e.key)),
      };

  test('a favourite outranks someone messaged far more', () {
    // Favouriting is the user saying outright who matters; nothing inferred
    // from traffic should be allowed to push that down the row.
    final ordered = frequentChats(
      [chat('quiet-favourite', favorite: true), chat('chatterbox')],
      volumes({'quiet-favourite': 2, 'chatterbox': 500}),
    );
    expect(ordered.map((c) => c.id), ['quiet-favourite', 'chatterbox']);
  });

  test('otherwise the busiest conversation comes first', () {
    final ordered = frequentChats(
      [chat('a'), chat('b'), chat('c')],
      volumes({'a': 3, 'b': 40, 'c': 12}),
    );
    expect(ordered.map((c) => c.id), ['b', 'c', 'a']);
  });

  test('channels and empty chats stay out of a row of faces', () {
    final ordered = frequentChats(
      [chat('#general', channel: true), chat('never-spoken'), chat('real')],
      volumes({'#general': 900, 'real': 4}),
    );
    expect(ordered.map((c) => c.id), ['real'],
        reason: 'a channel has no face, and silence is not frequency');
  });

  test('ties break by name so the row does not reshuffle between builds', () {
    final ordered = frequentChats(
      [chat('Zoe'), chat('Adam'), chat('Mia')],
      volumes({'Zoe': 5, 'Adam': 5, 'Mia': 5}),
    );
    expect(ordered.map((c) => c.id), ['Adam', 'Mia', 'Zoe']);
  });

  test('the row is capped', () {
    final many = [for (var i = 0; i < 30; i++) chat('p$i')];
    final ordered = frequentChats(
      many,
      volumes({for (var i = 0; i < 30; i++) 'p$i': 30 - i}),
      limit: 10,
    );
    expect(ordered.length, 10);
    expect(ordered.first.id, 'p0', reason: 'busiest first');
  });

  test('opening a search result remembers to return to chats', () {
    final route = Uri.parse(routeForChatFromSearch(chat('alice')));

    expect(route.path, '/chat/alice');
    expect(route.queryParameters['from'], 'search');
  });
}
