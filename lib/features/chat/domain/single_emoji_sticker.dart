import 'package:characters/characters.dart';

/// Returns the emoji when a text message should be rendered as an animated
/// sticker, or null when it should stay an ordinary text bubble.
///
/// The rule intentionally mirrors the user's typing, not Unicode internals:
/// one visible grapheme such as `😂`, `❤️`, `🇺🇦`, `👍🏽` or a ZWJ family counts
/// as one sticker. Two visible emoji, or emoji plus words, stay text.
String? singleEmojiStickerGlyph(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;

  final graphemes = trimmed.characters;
  if (graphemes.length != 1) return null;

  final glyph = graphemes.first;
  return _containsEmojiScalar(glyph) ? glyph : null;
}

bool _containsEmojiScalar(String glyph) {
  for (final rune in glyph.runes) {
    if (_isEmojiScalar(rune)) return true;
  }
  return false;
}

bool _isEmojiScalar(int rune) =>
    // Most modern emoji: faces, people, animals, food, objects, flags,
    // symbols, transport, activities and newer pictographs.
    rune >= 0x1F000 && rune <= 0x1FAFF ||
    // Misc symbols and dingbats: ❤️, ☺️, ☀️, ✨, ✅, etc.
    rune >= 0x2600 && rune <= 0x27BF ||
    // Arrows/shapes that phones commonly present as emoji.
    rune >= 0x2B00 && rune <= 0x2BFF ||
    // A few legacy symbols outside the blocks above that are emoji on phones.
    rune == 0x00A9 ||
    rune == 0x00AE ||
    rune == 0x203C ||
    rune == 0x2049 ||
    rune == 0x2122 ||
    rune == 0x2139 ||
    rune == 0x3030 ||
    rune == 0x303D ||
    rune == 0x3297 ||
    rune == 0x3299;
