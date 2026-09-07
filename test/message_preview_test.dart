import 'package:cubechat/features/chat/domain/message_preview.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:cubechat/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Message _m({
  required MessageKind kind,
  String text = '',
  String? fileName,
}) =>
    Message(
      id: 'm1',
      chatId: 'peer',
      text: text,
      sentAt: DateTime(2026),
      isMine: false,
      kind: kind,
      fileName: fileName,
    );

void main() {
  final t = lookupAppLocalizations(const Locale('en'));

  group('what a message is called where it cannot be drawn', () {
    test('a sticker is called by the emoji it was filed under', () {
      final m = _m(
        kind: MessageKind.image,
        text: Message.stickerMarkerFor('🔥'),
      );
      expect(messagePreview(m, t), '🔥 Sticker');
    });

    test('a sticker sent before there were emoji still has a name', () {
      final m = _m(kind: MessageKind.image, text: Message.stickerMarker);
      expect(messagePreview(m, t), 'Sticker');
    });

    test('a photo prefers its caption to the word photo', () {
      final withCaption = _m(kind: MessageKind.image, text: 'on the roof');
      expect(messagePreview(withCaption, t), '📷 on the roof');
      // The mime type rides in `text` when there is no caption, and it is not a
      // description of anything.
      final bare = _m(kind: MessageKind.image, text: 'image/jpeg');
      expect(messagePreview(bare, t), '📷 Photo');
    });

    test('voice, file and poll say what they are', () {
      expect(messagePreview(_m(kind: MessageKind.audio), t),
          '🎤 Voice message');
      expect(
        messagePreview(_m(kind: MessageKind.file, fileName: 'plan.pdf'), t),
        '📎 plan.pdf',
      );
      expect(
        messagePreview(_m(kind: MessageKind.poll, text: 'Lunch?'), t),
        '📊 Lunch?',
      );
    });

    test('text is itself', () {
      expect(
        messagePreview(_m(kind: MessageKind.text, text: 'hello'), t),
        'hello',
      );
    });
  });

  group('a reaction on your own message', () {
    // The chat row and the reply quote ask different questions of the same
    // message. "Somebody reacted to what you said" is the newest thing that
    // happened in the conversation, which is what a row reports. A quote is
    // answering "what am I replying to", and there the reaction does not add
    // to the answer, it replaces it: a reply to a line of yours that somebody
    // had reacted to came out quoting the reaction and not the line.
    //
    // Reported from a screenshot of exactly that. It survived because it only
    // happens on your own messages — quoting somebody else's always looked
    // right, which is most of the quoting anybody does while testing.
    Message mine() => Message(
          id: 'm1',
          chatId: 'peer',
          text: 'Та ну все равно',
          sentAt: DateTime(2026),
          isMine: true,
          reactions: const {
            '🔥': {'them'},
          },
        );

    test('is what the chat row reports', () {
      expect(messagePreview(mine(), t), '🔥 to your message');
    });

    test('is not what a reply quotes', () {
      expect(messageContentPreview(mine(), t), 'Та ну все равно');
    });

    test('does not change a message nobody reacted to', () {
      final plain = _m(kind: MessageKind.text, text: 'hello');
      expect(messageContentPreview(plain, t), messagePreview(plain, t));
    });

    test('leaves a sticker named by its emoji either way', () {
      final sticker = Message(
        id: 'm2',
        chatId: 'peer',
        text: Message.stickerMarkerFor('🐱'),
        sentAt: DateTime(2026),
        isMine: true,
        kind: MessageKind.image,
        reactions: const {
          '🔥': {'them'},
        },
      );
      expect(messageContentPreview(sticker, t), '🐱 Sticker');
    });
  });

  group('a row that kept only the text', () {
    test('still names a sticker', () {
      expect(storedTextPreview(Message.stickerMarkerFor('🐱'), t), '🐱 Sticker');
      expect(storedTextPreview(Message.stickerMarker, t), 'Sticker');
    });

    test('leaves anything it cannot be sure about alone', () {
      expect(storedTextPreview('see you at six', t), 'see you at six');
    });
  });
}
