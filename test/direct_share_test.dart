import 'package:cubechat/features/airdrop/data/share_inbox.dart';
import 'package:cubechat/features/chats/data/saved_messages.dart';
import 'package:cubechat/features/chats/models/chat.dart';
import 'package:cubechat/features/share/data/direct_share.dart';
import 'package:flutter_test/flutter_test.dart';

Chat _chat(String id, String name, {bool channel = false}) => Chat(
      id: id,
      peerId: id,
      peerName: name,
      lastMessage: '',
      lastTime: DateTime(2026),
      unreadCount: 0,
      isMesh: false,
      isChannel: channel,
    );

/// What the system share sheet is offered, and what a tapped tile resolves to.
void main() {
  test('people only, in list order, at most four', () {
    final targets = pickDirectShareTargets([
      _chat('a', 'Аня'),
      _chat('#room', 'Room', channel: true),
      _chat(savedChatId, 'Saved'),
      _chat('b', '  '),
      _chat('c', 'Борис'),
      _chat('d', 'Віка'),
      _chat('e', 'Гліб'),
      _chat('f', 'Дана'),
    ]);
    expect(targets.map((t) => t.id), ['a', 'c', 'd', 'e']);
    expect(targets.first.name, 'Аня');
  });

  test('a tile resolves to its chat, and to nothing once the chat is gone', () {
    final chats = [_chat('a', 'Аня'), _chat('#room', 'Room', channel: true)];
    expect(chatForDirectShare(chats, 'a')?.peerName, 'Аня');
    expect(chatForDirectShare(chats, 'gone'), isNull);
    expect(chatForDirectShare(chats, '#room'), isNull);
    expect(chatForDirectShare(chats, null), isNull);
  });

  test('the platform target survives parsing, an empty one does not', () {
    expect(
      SharedBundle.fromPlatform(files: null, text: 'hi', target: 'a')
          .targetChatId,
      'a',
    );
    expect(
      SharedBundle.fromPlatform(files: null, text: 'hi', target: '')
          .targetChatId,
      isNull,
    );
    expect(
      SharedBundle.fromPlatform(files: null, text: 'hi').targetChatId,
      isNull,
    );
  });
}
