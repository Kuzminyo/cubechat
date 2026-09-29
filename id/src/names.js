// The rules a @name has to pass. The Dart twin is
// lib/features/cube_id/domain/cube_name.dart; both are pinned by
// test/fixtures/name-cases.json, so they cannot drift apart silently.

const FORMAT = /^[a-z0-9_]{3,20}$/;

// Names that would let somebody pose as the project or as staff.
const RESERVED = new Set([
  'admin', 'administrator', 'root', 'support', 'help', 'helpdesk', 'official',
  'moderator', 'mod', 'staff', 'team', 'security', 'system', 'null', 'undefined',
  'cubechat', 'cube', 'cubeid', 'cube_id', 'apple', 'google', 'brave1',
]);

// Any name containing one of these is taken as posing as the project.
const RESERVED_PARTS = ['cubechat', 'admin', 'support', 'moderator'];

// Names are latin-only, so the filter's Cyrillic stems
// (lib/features/moderation/domain/profanity.dart) appear here transliterated.
// Matched as substrings: a name has no spaces to split words on.
const OBSCENE = [
  'fuck', 'shit', 'cunt', 'bitch', 'whore', 'slut', 'nigg', 'fagg', 'retard',
  'dickhead', 'asshole', 'bastard',
  'huy', 'hui', 'xuy', 'xui', 'pizd', 'pezd', 'blya', 'suka', 'suki', 'pidor',
  'pidar', 'gandon', 'mudak', 'eblan', 'zalup', 'shluh', 'shlyuh', 'kurva',
];

// Innocent words that contain a stem. Removed before the substring test, so
// "shiitake" passes and "shiitakeshit" still does not.
const INNOCENT = ['shiitake', 'scunthorpe', 'sukanya', 'bass', 'hui_ling', 'niggle'];

export function normalizeName(raw) {
  let s = String(raw ?? '').trim();
  if (s.startsWith('@')) s = s.slice(1);
  return s.toLowerCase();
}

export function nameProblem(name) {
  if (!FORMAT.test(name)) return 'invalid';
  if (RESERVED.has(name)) return 'reserved';
  if (RESERVED_PARTS.some((part) => name.includes(part))) return 'reserved';
  let scrubbed = name;
  for (const word of INNOCENT) scrubbed = scrubbed.split(word).join('_');
  if (OBSCENE.some((stem) => scrubbed.includes(stem))) return 'reserved';
  return null;
}
