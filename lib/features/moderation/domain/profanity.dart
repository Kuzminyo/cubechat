import '../../chat/models/message.dart';

/// Deliberately short, stem-based list. This is a local safety affordance,
/// not a classifier; innocent words sharing a stem are allowed explicitly.
const _stems = <String>[
  'хуй',
  'хуе',
  'хуя',
  'пизд',
  'пезд',
  'еб',
  'ёб',
  'бля',
  'сук',
  'мудак',
  'гандон',
  'пидор',
  'підар',
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

const _allowed = <String>{
  'скипидар',
  'потребля',
  'оскорбля',
  'страхуй',
  'команд',
  'document',
  'scunthorpe',
  'assess',
  'cocktail',
  'shitake',
};

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
    if (_allowed.contains(token)) continue;
    if (_stems.any(token.startsWith)) return true;
  }
  return false;
}

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
