import 'package:cubechat/features/chat/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

/// A message that is nothing but emoji is drawn large and without a bubble,
/// the way every messenger draws one — a bubble is a frame for text, and there
/// is no text here.
///
/// The counting is the part worth pinning. A single emoji is routinely several
/// code points: a skin tone is a modifier, a family is people joined by
/// zero-width joiners, a flag is two regional indicators. Counting runes calls
/// one waving hand three emoji and refuses to enlarge it, which is the bug this
/// was written to avoid rather than to fix afterwards.
Message _text(String body) => Message(
      id: 'm1',
      chatId: 'peer',
      text: body,
      sentAt: DateTime(2026, 9, 6),
      isMine: true,
    );

void main() {
  test('one emoji is one', () {
    expect(_text('😂').bareEmojiCount, 1);
  });

  test('two are two, which is the case that was reported', () {
    expect(_text('😂😂').bareEmojiCount, 2);
  });

  test('surrounding whitespace does not make it text', () {
    expect(_text('  🔥  ').bareEmojiCount, 1);
    expect(_text('😀 😀').bareEmojiCount, 2);
  });

  test('one emoji built from several code points is still one', () {
    // A skin tone is a modifier on the hand, not a second emoji.
    expect(_text('👋🏽').bareEmojiCount, 1);
    // A family is people held together by zero-width joiners.
    expect(_text('👨‍👩‍👧').bareEmojiCount, 1);
    // A flag is two regional indicators.
    expect(_text('🇺🇦').bareEmojiCount, 1);
  });

  test('a word anywhere in it makes it a message again', () {
    expect(_text('😂 lol').bareEmojiCount, isNull);
    expect(_text('ха 😂').bareEmojiCount, isNull);
    expect(_text('!').bareEmojiCount, isNull);
    expect(_text('').bareEmojiCount, isNull);
    expect(_text('   ').bareEmojiCount, isNull);
  });

  test('past a handful it is a message again', () {
    // Three is the cap: past that they stop being a reaction and start being
    // content, and a wall of them at sticker size is a screenful.
    expect(_text('😀😀😀').bareEmojiCount, 3);
    expect(_text('😀😀😀😀').bareEmojiCount, isNull);
  });

  test('a sticker is not this', () {
    // Stickers already have their own path, and it draws them from a picture.
    final sticker = Message(
      id: 'm2',
      chatId: 'peer',
      text: Message.stickerMarkerFor('😂'),
      sentAt: DateTime(2026, 9, 6),
      isMine: true,
      kind: MessageKind.image,
      imagePath: '/tmp/s.webp',
    );
    expect(sticker.isSticker, isTrue);
    expect(sticker.bareEmojiCount, isNull);
  });
}
