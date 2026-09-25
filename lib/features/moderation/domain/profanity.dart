import '../../chat/models/message.dart';

/// Deliberately short, stem-based list. App Review asks for a filter, not a
/// classifier: this folds the obvious words away on this phone and nothing
/// more. A token matches when it *starts* with a stem, so a stem hidden
/// inside a longer word ("скипидар", "потребляти") never matches at all; the
/// words that do *start* with a stem and are innocent are listed in
/// [_allowedPrefixes].
///
/// 'сук' was a bare stem in the handoff and folded "сукня" (a dress) and
/// "сукупність" (a totality) — two ordinary Ukrainian words. It is spelled
/// out by form instead (review of 2026-09-25).
const _stems = <String>[
  'хуй',
  'хуе',
  'хуя',
  'хуи',
  'пизд',
  'пезд',
  'еб',
  'ёб',
  'бля',
  'сука',
  'суки',
  'суку',
  'сукам',
  'суках',
  'сукой',
  'сукою',
  'сучар',
  'сучий',
  'мудак',
  'гандон',
  'пидор',
  'пидар',
  'підар',
  'підор',
  'шлюх',
  'курв',
  'залуп',
  'похер',
  'нахер',
  'ублюд',
  'говн',
  'сран',
  'дроч',
  'минет',
  'fuck',
  'shit',
  'cunt',
  'bitch',
  'whore',
  'slut',
  'motherfuck',
  'nigg',
  'fagg',
  'retard',
  'dickhead',
  'asshole',
  'bastard',
];

/// Innocent words that begin with a stem. A prefix list, not a word list: the
/// handoff matched these as exact tokens, so "бляшанка" was allowed only in
/// the one form nobody writes and "бляшанки" still folded.
const _allowedPrefixes = <String>[
  'бляш', // бляшанка — a tin can
  'блях', // бляха — a badge
  'ебол', // Ебола, as Ukrainian spells Ebola
  'сукуп', // сукупність, сукупний — begins with the form 'суку'
  'shiitake',
  'shitake',
  'niggl', // niggle
  'retardant',
];

const _lookalikes = <String, String>{
  'a': 'а',
  'e': 'е',
  'o': 'о',
  'p': 'р',
  'c': 'с',
  'x': 'х',
  'y': 'у',
  'k': 'к',
  'm': 'м',
  't': 'т',
  'h': 'н',
  'b': 'в',
};

final _word = RegExp(r'[a-zа-яіїєґ]+', caseSensitive: false);
final _punctuation = RegExp(r'(?<=[a-zа-яіїєґ])[*._-]+(?=[a-zа-яіїєґ])');
final _spacedLetters = RegExp(
  r'(?<![a-zа-яіїєґ])(?:[a-zа-яіїєґ]\s+){2,}[a-zа-яіїєґ](?![a-zа-яіїєґ])',
);

String normaliseForFilter(String input) {
  var text = input.toLowerCase().replaceAll('ё', 'е');
  text = text.replaceAll(_punctuation, '');
  text = text.replaceAllMapped(
    RegExp(r'([a-zа-яіїєґ])\1{2,}'),
    (match) => match.group(1)!,
  );
  text = text.replaceAllMapped(
    _spacedLetters,
    (match) => match.group(0)!.replaceAll(RegExp(r'\s+'), ''),
  );
  text = text.replaceAllMapped(_word, (match) {
    final token = match.group(0)!;
    if (!RegExp(r'[а-яіїєґ]').hasMatch(token)) return token;
    return token
        .split('')
        .map((letter) => _lookalikes[letter] ?? letter)
        .join();
  });
  return text.replaceAll('fck', 'fuck');
}

bool containsProfanity(String text) {
  final normalised = normaliseForFilter(text);
  for (final match in _word.allMatches(normalised)) {
    final token = match.group(0)!;
    if (_allowedPrefixes.any(token.startsWith)) continue;
    if (_stems.any(token.startsWith)) return true;
  }
  return false;
}

/// Who counts as a stranger for the filter.
///
/// The app keeps no contact list to ask. `knownPeers` holds everybody whose
/// key this phone has ever seen, which includes every sender, so the
/// handoff's "in knownPeers" test made the filter a no-op in direct chats;
/// and the Contacts tab is "anyone with history", which a stranger's first
/// message already is. So a conversation stops being a stranger's once you
/// have written in it yourself (review of 2026-09-25). Unknown history — a
/// chat whose messages are not loaded yet — counts as a stranger's, so the
/// fold errs toward hiding.
bool hasWrittenIn(Iterable<Message>? history) =>
    history?.any((m) => m.isMine) ?? false;

bool shouldFilter({
  required Message message,
  required bool isChannel,
  required bool fromContact,
  required bool enabled,
}) =>
    enabled &&
    !message.isMine &&
    (isChannel || !fromContact) &&
    message.kind == MessageKind.text &&
    containsProfanity(message.text);
