/// The rules a Cube ID @name has to pass. The server's twin is
/// `id/src/names.js`; both are pinned by `id/test/fixtures/name-cases.json`,
/// so the app never offers a name the server would refuse.
library;

const String cubeIdHost = 'id.cubechat.tech';

enum CubeNameProblem { invalid, reserved }

final RegExp _format = RegExp(r'^[a-z0-9_]{3,20}$');

/// Names that would let somebody pose as the project or as staff.
const Set<String> _reserved = {
  'admin',
  'administrator',
  'root',
  'support',
  'help',
  'helpdesk',
  'official',
  'moderator',
  'mod',
  'staff',
  'team',
  'security',
  'system',
  'null',
  'undefined',
  'cubechat',
  'cube',
  'cubeid',
  'cube_id',
  'apple',
  'google',
  'brave1',
};

const List<String> _reservedParts = [
  'cubechat',
  'admin',
  'support',
  'moderator',
];

/// Latin transliterations of the filter's stems in
/// `lib/features/moderation/domain/profanity.dart`; names have no spaces, so
/// these match as substrings.
const List<String> _obscene = [
  'fuck',
  'shit',
  'cunt',
  'bitch',
  'whore',
  'slut',
  'nigg',
  'fagg',
  'retard',
  'dickhead',
  'asshole',
  'bastard',
  'huy',
  'hui',
  'xuy',
  'xui',
  'pizd',
  'pezd',
  'blya',
  'suka',
  'suki',
  'pidor',
  'pidar',
  'gandon',
  'mudak',
  'eblan',
  'zalup',
  'shluh',
  'shlyuh',
  'kurva',
];

/// Innocent words that contain a stem; removed before the substring test.
const List<String> _innocent = [
  'shiitake',
  'scunthorpe',
  'sukanya',
  'bass',
  'hui_ling',
  'niggle',
];

/// Whether text typed into the add-contact field is an @name rather than a
/// pasted card. A card is hundreds of characters with a scheme; a name is at
/// most twenty of `[a-z0-9_]` — the two cannot be confused. A reserved name
/// still counts: the lookup simply finds nobody.
bool looksLikeCubeName(String raw) =>
    cubeNameProblem(normalizeCubeName(raw)) != CubeNameProblem.invalid;

String normalizeCubeName(String raw) {
  var s = raw.trim();
  if (s.startsWith('@')) s = s.substring(1);
  return s.toLowerCase();
}

CubeNameProblem? cubeNameProblem(String name) {
  if (!_format.hasMatch(name)) return CubeNameProblem.invalid;
  if (_reserved.contains(name)) return CubeNameProblem.reserved;
  if (_reservedParts.any(name.contains)) return CubeNameProblem.reserved;
  var scrubbed = name;
  for (final word in _innocent) {
    scrubbed = scrubbed.split(word).join('_');
  }
  if (_obscene.any(scrubbed.contains)) return CubeNameProblem.reserved;
  return null;
}
