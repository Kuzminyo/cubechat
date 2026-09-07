/// The pack that ships with the app: a cat, and a set of faces.
///
/// **What this replaces.** The starter pack used to be a list of Unicode
/// glyphs, painted into PNGs on the phone the first time each was picked.
/// Nothing was bundled and nothing was fetched, which was the right answer
/// while there was no artwork — but what it produced was the system emoji font
/// at 320 pixels, which is not a sticker, it is a big emoji.
///
/// These are drawings, and they move. Each one ships twice: an animation the
/// bubble plays, and a still the picker draws. The picker never animates —
/// seventy-two loops running at once to help somebody choose one is exactly
/// the kind of thing this codebase keeps taking back out — so the still is not
/// an optimisation, it is what that screen is for.
///
/// The artwork lives in `design-previews/matcha-motion-v6` at 512 px and 57
/// frames; `tool/build_sticker_assets.py` is what turns it into these, and the
/// reasoning about sizes and frame rates is written there.
abstract final class StickerPack {
  static const String _dir = 'assets/stickers';

  /// The animation, for a bubble.
  static String animation(String name) => '$_dir/$name.webp';

  /// The still, for a picker cell — and for anywhere else that would otherwise
  /// be running a loop nobody is looking at.
  static String still(String name) => '$_dir/$name.png';

  /// The cat, in the order the picker shows it.
  static const List<String> cats = <String>[
    'cat-wave',
    'cat-love',
    'cat-laugh',
    'cat-hug',
    'cat-approve',
    'cat-thanks',
    'cat-party',
    'cat-birthday',
    'cat-cool',
    'cat-victory',
    'cat-support',
    'cat-flower',
    'cat-matcha',
    'cat-cookie',
    'cat-popcorn',
    'cat-morning',
    'cat-cozy',
    'cat-sleep',
    'cat-tired',
    'cat-waiting',
    'cat-hurry',
    'cat-work',
    'cat-gaming',
    'cat-music',
    'cat-thinking',
    'cat-secret',
    'cat-shy',
    'cat-peek',
    'cat-surprise',
    'cat-sad',
    'cat-sorry',
    'cat-recover',
    'cat-angry',
    'cat-nope',
    'cat-facepalm',
    'cat-rain',
  ];

  /// The drawn faces, in the order the picker shows them.
  static const List<String> faces = <String>[
    'emoji-smile',
    'emoji-grin',
    'emoji-laugh',
    'emoji-rofl',
    'emoji-giggle',
    'emoji-wink',
    'emoji-smirk',
    'emoji-cool',
    'emoji-love',
    'emoji-heart',
    'emoji-kiss',
    'emoji-hugging',
    'emoji-starry',
    'emoji-party',
    'emoji-fire',
    'emoji-clap',
    'emoji-approve',
    'emoji-thanks',
    'emoji-salute',
    'emoji-angel',
    'emoji-relieved',
    'emoji-sleepy',
    'emoji-thinking',
    'emoji-skeptical',
    'emoji-unamused',
    'emoji-eyeroll',
    'emoji-shush',
    'emoji-zipper',
    'emoji-sweat',
    'emoji-pleading',
    'emoji-sad',
    'emoji-sobbing',
    'emoji-surprise',
    'emoji-mindblown',
    'emoji-angry',
    'emoji-tongue',
  ];

  /// Everything, in the order it is offered.
  static const List<String> all = <String>[...cats, ...faces];

  /// The emoji each drawn face stands for.
  ///
  /// Two things read it. The picker files a sticker under one, which is what
  /// the chat list and a reply quote show in place of a picture they cannot
  /// draw — see [Message.stickerMarkerFor]. And a message that is nothing but
  /// that one emoji is drawn as the animation instead of as a glyph, which is
  /// the whole of "one emoji moves, several do not".
  ///
  /// Only where the drawing and the emoji plainly mean the same thing. A face
  /// with no obvious glyph is better with none than with an approximate one:
  /// the mapping is also what decides whether typing an emoji turns into a
  /// drawing, and a surprising one there is worse than a plain glyph.
  static const Map<String, String> glyphFor = <String, String>{
    'emoji-smile': '🙂',
    'emoji-grin': '😁',
    'emoji-laugh': '😂',
    'emoji-rofl': '🤣',
    'emoji-giggle': '🤭',
    'emoji-wink': '😉',
    'emoji-smirk': '😏',
    'emoji-cool': '😎',
    'emoji-love': '😍',
    'emoji-heart': '❤️',
    'emoji-kiss': '😘',
    'emoji-hugging': '🤗',
    'emoji-starry': '🤩',
    'emoji-party': '🥳',
    'emoji-fire': '🔥',
    'emoji-clap': '👏',
    'emoji-approve': '👍',
    'emoji-thanks': '🙏',
    'emoji-salute': '🫡',
    'emoji-angel': '😇',
    'emoji-relieved': '😌',
    'emoji-sleepy': '😴',
    'emoji-thinking': '🤔',
    'emoji-skeptical': '🤨',
    'emoji-unamused': '😒',
    'emoji-eyeroll': '🙄',
    'emoji-shush': '🤫',
    'emoji-zipper': '🤐',
    'emoji-sweat': '😅',
    'emoji-pleading': '🥺',
    'emoji-sad': '😢',
    'emoji-sobbing': '😭',
    'emoji-surprise': '😱',
    'emoji-mindblown': '🤯',
    'emoji-angry': '😡',
    'emoji-tongue': '😛',
    'cat-wave': '👋',
    'cat-love': '😻',
    'cat-laugh': '😹',
    'cat-hug': '🤗',
    'cat-approve': '👍',
    'cat-thanks': '🙏',
    'cat-party': '🎉',
    'cat-birthday': '🎂',
    'cat-cool': '😎',
    'cat-victory': '✌️',
    'cat-support': '💪',
    'cat-flower': '🌸',
    'cat-matcha': '🍵',
    'cat-cookie': '🍪',
    'cat-popcorn': '🍿',
    'cat-morning': '☀️',
    'cat-cozy': '🧸',
    'cat-sleep': '😴',
    'cat-tired': '🥱',
    'cat-waiting': '🕐',
    'cat-hurry': '🏃',
    'cat-work': '💻',
    'cat-gaming': '🎮',
    'cat-music': '🎵',
    'cat-thinking': '🤔',
    'cat-secret': '🤫',
    'cat-shy': '☺️',
    'cat-peek': '👀',
    'cat-surprise': '😲',
    'cat-sad': '😿',
    'cat-sorry': '🙇',
    'cat-recover': '🤒',
    'cat-angry': '😾',
    'cat-nope': '🙅',
    'cat-facepalm': '🤦',
    'cat-rain': '🌧️',
  };

  /// The drawn face for a single emoji, or null when there is no drawing of it.
  ///
  /// Built from [glyphFor] rather than written out again, so the two cannot
  /// disagree. Faces only: the cat is a sticker somebody picks, not something
  /// typing `👋` should silently turn into.
  static final Map<String, String> faceForGlyph = <String, String>{
    for (final name in faces)
      if (glyphFor[name] != null) glyphFor[name]!: name,
  };
}
