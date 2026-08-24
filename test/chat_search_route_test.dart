import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/features/chat/domain/message_search.dart';
import 'package:cubechat/features/chat/presentation/chat_screen.dart';
import 'package:flutter_test/flutter_test.dart';

Message _message({
  required String id,
  required String text,
  String? fileName,
  String? authorName,
  MessageKind kind = MessageKind.text,
}) =>
    Message(
      id: id,
      chatId: 'chat',
      text: text,
      sentAt: DateTime(2026),
      isMine: false,
      kind: kind,
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
  test('conversation search never matches the plumbing inside a message', () {
    // What "one letter came back with messages it is not in" was made of: a
    // photo keeps its mime type in `text`, a voice note keeps `audio/aac`, a
    // sticker keeps its marker, and a shared card keeps base64 — between them
    // they hold most of the alphabet.
    final messages = [
      _message(id: 'photo', text: 'image/jpeg', kind: MessageKind.image),
      _message(id: 'voice', text: 'audio/aac', kind: MessageKind.audio),
      _message(
        id: 'sticker',
        text: Message.stickerMarkerFor('🔥'),
        kind: MessageKind.image,
      ),
      _message(id: 'card', text: 'cubechat:contact:v1:eyJpZCI6IngifQ'),
      _message(id: 'words', text: 'a message with words in it'),
    ];

    for (final letter in ['a', 'e', 'g', 'i', 'm', 'j', 'x', 'v', 'c']) {
      final ids = messagesMatchingQuery(messages, letter).map((m) => m.id);
      expect(
        ids.where((id) => id != 'words'),
        isEmpty,
        reason: '"$letter" matched plumbing: ${ids.toList()}',
      );
    }
  });

  test('a caption is searchable, and a sticker by its emoji', () {
    final messages = [
      _message(
        id: 'captioned',
        text: 'on the roof at sunset',
        kind: MessageKind.image,
      ),
      _message(
        id: 'sticker',
        text: Message.stickerMarkerFor('🔥'),
        kind: MessageKind.image,
      ),
      _message(id: 'poll', text: 'Lunch at one?', kind: MessageKind.poll),
    ];

    expect(messagesMatchingQuery(messages, 'sunset').single.id, 'captioned');
    expect(messagesMatchingQuery(messages, '🔥').single.id, 'sticker');
    expect(messagesMatchingQuery(messages, 'lunch').single.id, 'poll');
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

  test('the header follows the live route, not the last message', () {
    // This reverses what the header used to do, deliberately. It answered with
    // the route of the last message that carried one, so a phone that had been
    // writing over the internet and then met the other person on Bluetooth
    // went on claiming the internet until something else was sent. The line at
    // the top of a conversation is read as "how am I connected", and about the
    // present it was simply wrong.
    final messages = [
      Message(
        id: '1',
        chatId: 'chat',
        text: 'hello',
        sentAt: DateTime(2026),
        isMine: true,
        route: MessageRoute.internet,
      ),
    ];

    expect(displayedChatRoute(messages, ChatRoute.bluetooth).route,
        ChatRoute.bluetooth);
  });

  test('hops come from the conversation, and only for the mesh', () {
    // Availability cannot know a hop count; a delivery can. But it only means
    // anything while the mesh is the road actually in use.
    final messages = [
      Message(
        id: 'old',
        chatId: 'chat',
        text: 'first',
        sentAt: DateTime(2026),
        isMine: true,
        route: MessageRoute.mesh,
        routeHops: 5,
      ),
      Message(
        id: 'new',
        chatId: 'chat',
        text: 'second',
        sentAt: DateTime(2026, 1, 2),
        isMine: true,
        route: MessageRoute.mesh,
        routeHops: 3,
      ),
    ];

    expect(displayedChatRoute(messages, ChatRoute.mesh),
        (route: ChatRoute.mesh, hops: 3));
    expect(displayedChatRoute(messages, ChatRoute.bluetooth),
        (route: ChatRoute.bluetooth, hops: null));
  });

  test('a history with no routes still answers with availability', () {
    final result = displayedChatRoute(
        [_message(id: 'legacy', text: 'old')], ChatRoute.internet);
    expect(result, (route: ChatRoute.internet, hops: null));
  });
}
