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
