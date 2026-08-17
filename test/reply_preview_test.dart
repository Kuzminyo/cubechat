import 'package:cubechat/features/chat/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

Message _message({
  String id = 'm1',
  String? replyTo,
  String? replyPreview,
}) =>
    Message(
      id: id,
      chatId: 'peer',
      text: 'hello',
      sentAt: DateTime(2026, 8, 17, 12),
      isMine: true,
      replyToWireId: replyTo,
      replyPreview: replyPreview,
    );

/// What a reply quotes when the message it quotes cannot be found.
///
/// The quote box was rendered entirely by looking the target up in the store,
/// and drew a bare "…" whenever that missed. It missed often — cleared history,
/// a message filed under a different id, one that has not arrived yet — and it
/// missed on every reply to a sticker, which is what was reported.
void main() {
  group('a reply carries what it was answering', () {
    test('the id and the snippet are separate things', () {
      final m = _message(replyTo: 'abc123', replyPreview: '🔥 Sticker');
      // One is navigation — a tap on the quote jumps there — and the other is
      // content. Only the second has to survive the message it points at.
      expect(m.replyToWireId, 'abc123');
      expect(m.replyPreview, '🔥 Sticker');
    });

    test('a reply from the wire has no snippet, only the id', () {
      // Nothing carries the preview across, so the far side still resolves the
      // quote by looking it up — and null is what tells the box to do that.
      final m = _message(replyTo: 'abc123');
      expect(m.replyPreview, isNull);
    });

    test('an ordinary message has neither', () {
      final m = _message();
      expect(m.replyToWireId, isNull);
      expect(m.replyPreview, isNull);
    });
  });

  group('it survives being stored', () {
    test('copyWith keeps the snippet', () {
      // Status changes are the common case — sending to delivered to read —
      // and dropping the quote on the first of them would make the box go
      // blank a second after it was sent.
      final m = _message(replyTo: 'abc123', replyPreview: '🔥 Sticker')
          .copyWith(status: MessageStatus.delivered);
      expect(m.replyPreview, '🔥 Sticker');
      expect(m.replyToWireId, 'abc123');
      expect(m.status, MessageStatus.delivered);
    });
  });
}
