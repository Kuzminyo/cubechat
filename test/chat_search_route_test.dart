import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/presentation/chat_screen.dart';
import 'package:flutter_test/flutter_test.dart';

Message _message({
  required String id,
  required String text,
  String? fileName,
  String? authorName,
}) =>
    Message(
      id: id,
      chatId: 'chat',
      text: text,
      sentAt: DateTime(2026),
      isMine: false,
      fileName: fileName,
      authorName: authorName,
    );

void main() {
  test('conversation search is case-insensitive and preserves timeline order',
      () {
    final messages = [
      _message(id: '1', text: 'First HELLO'),
      _message(id: '2', text: 'nothing'),
      _message(id: '3', text: 'hello again'),
    ];

    expect(
      messagesMatchingQuery(messages, ' hello ').map((message) => message.id),
      ['1', '3'],
    );
  });

  test('conversation search includes file names and channel authors', () {
    final messages = [
      _message(id: 'file', text: '', fileName: 'Vacation.JPG'),
      _message(id: 'author', text: 'ok', authorName: 'Kuzminyo'),
    ];

    expect(messagesMatchingQuery(messages, 'jpg').single.id, 'file');
    expect(messagesMatchingQuery(messages, 'kuz').single.id, 'author');
    expect(messagesMatchingQuery(messages, '   '), isEmpty);
  });

  test('conversation search normalizes cyrillic variants and split words', () {
    final messages = [
      _message(id: 'city', text: 'Привіт, Семён з Києва'),
      _message(id: 'other', text: 'нічого схожого'),
    ];

    expect(messagesMatchingQuery(messages, 'привит семен').single.id, 'city');
    expect(messagesMatchingQuery(messages, 'киева').single.id, 'city');
  });
  test('route priority follows the actual send order', () {
    expect(
      resolveChatRoute(
        directBluetooth: true,
        meshAvailable: true,
        relayAvailable: true,
      ),
      ChatRoute.bluetooth,
    );
    expect(
      resolveChatRoute(
        directBluetooth: false,
        meshAvailable: true,
        relayAvailable: true,
      ),
      ChatRoute.mesh,
    );
    expect(
      resolveChatRoute(
        directBluetooth: false,
        meshAvailable: false,
        relayAvailable: true,
      ),
      ChatRoute.internet,
    );
    expect(
      resolveChatRoute(
        directBluetooth: false,
        meshAvailable: false,
        relayAvailable: false,
      ),
      ChatRoute.queued,
    );
  });

  test('stored actual route overrides current transport availability', () {
    final messages = [
      Message(
        id: '1',
        chatId: 'chat',
        text: 'hello',
        sentAt: DateTime(2026),
        isMine: true,
        route: MessageRoute.mesh,
        routeHops: 3,
      ),
    ];
    final result = displayedChatRoute(messages, ChatRoute.bluetooth);
    expect(result.route, ChatRoute.mesh);
    expect(result.hops, 3);
  });

  test('availability remains fallback for legacy history', () {
    final result = displayedChatRoute(
        [_message(id: 'legacy', text: 'old')], ChatRoute.internet);
    expect(result, (route: ChatRoute.internet, hops: null));
  });
}
