import 'package:cubechat/features/chat/domain/single_emoji_sticker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('one visible emoji becomes an animated sticker candidate', () {
    expect(singleEmojiStickerGlyph('😂'), '😂');
    expect(singleEmojiStickerGlyph(' ❤️ '), '❤️');
    expect(singleEmojiStickerGlyph('👍🏽'), '👍🏽');
    expect(singleEmojiStickerGlyph('🇺🇦'), '🇺🇦');
    expect(singleEmojiStickerGlyph('👨‍👩‍👧‍👦'), '👨‍👩‍👧‍👦');
  });

  test('multiple emoji or words stay ordinary text', () {
    expect(singleEmojiStickerGlyph('😂😂'), isNull);
    expect(singleEmojiStickerGlyph('😂 ок'), isNull);
    expect(singleEmojiStickerGlyph('ок'), isNull);
    expect(singleEmojiStickerGlyph(''), isNull);
  });
}
