import 'package:cubechat/features/chat/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

Message _image(String text) => Message(
      id: 'm1',
      chatId: 'chat',
      text: text,
      sentAt: DateTime(2026),
      isMine: true,
      kind: MessageKind.image,
      imagePath: '/tmp/x.png',
    );

void main() {
  test('a sticker is an image carrying the marker', () {
    expect(_image(Message.stickerMarker).isSticker, isTrue);
    // And the marker is never mistaken for something the sender typed.
    expect(_image(Message.stickerMarker).imageCaption, isNull);
  });

  test('an ordinary photo is not one', () {
    expect(_image('image/jpeg').isSticker, isFalse);
    expect(_image('look at this').isSticker, isFalse);
    expect(_image('look at this').imageCaption, 'look at this');
  });

  test('text that merely says the marker is not a sticker', () {
    // Only a picture can be one; the marker alone is a message about nothing.
    final text = Message(
      id: 'm2',
      chatId: 'chat',
      text: Message.stickerMarker,
      sentAt: DateTime(2026),
      isMine: false,
      kind: MessageKind.text,
    );
    expect(text.isSticker, isFalse);
  });
}
