# Cube ID names (`@name`) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a person take a short unique `@name` that points at their existing signed contact card, find others by `@name`, and choose who may reach them from the internet as a stranger (everyone / request / nobody).

**Architecture:** A new Node service `id/` (`cubechat-id`, SQLite via `node:sqlite`, served at `https://id.cubechat.tech` behind the existing Caddy) stores `name → PeerAnnouncement bytes`. Every change is a Nostr event of kind 24243 signed by the owner's Nostr key; the card's embedded Nostr key must equal the event's `pubkey`, so nobody can hang someone else's card on a name, and the phone verifies the card's Ed25519 signature on lookup exactly as it does for a QR card. The app adds `lib/features/cube_id/` (name rules, proof-of-work, HTTP client, controller, screen), a lookup path in the existing "add contact" field, a three-way "who can message me from the internet" setting, and a `MessageRequestsController` that the inbound path fills and the chat list folds into a Requests drawer. No new mesh wire types.

**Tech Stack:** Node ≥ 22 (`node:sqlite`, `node:crypto` Ed25519, `node:test`), `@noble/curves` + `@noble/hashes` (already used by `push/`); Flutter/Riverpod Notifiers, Hive encrypted settings box, `cryptography` (`DartSha256.hashSync`), in-repo `Secp256k1NostrSigner`.

**Spec:** `docs/superpowers/specs/2026-09-29-cube-id-names-design.md` (Russian; authority). Sub-stage 1b (recovery e-mail) is **out of scope** for this plan.

## Global Constraints

- Edit source with Edit/Write only (a hook blocks shell rewrites; shells mangle Cyrillic). Strict analyzer; `flutter analyze` must show 0 errors and 0 warnings — grep both `error -`/`warning -` and `error •`/`warning •`.
- Every user-visible string goes in both `lib/l10n/app_en.arb` and `lib/l10n/app_uk.arb`, then `flutter gen-l10n`; commit the regenerated `lib/l10n/app_localizations*.dart`.
- The main checkout holds other people's uncommitted work (design-previews deletions, `assets/stickers/cat-matcha.webp`, `tool/build_sticker_assets.py`, untracked `.agents/`, `.codex_edit_headless_fix.py`, `push/package-lock.json`, `tool/__pycache__/`). Never stage, revert or reformat those; always `git add <explicit paths>`.
- `MessagingService` changes are additive only (CLAUDE.md). Load the `wire-protocol` skill before touching `lib/core/transport/**`; this plan adds no `InnerPayloadType`, `FrameType`, cipher tag or manifest version.
- Exact values from the spec: name regex `^[a-z0-9_]{3,20}$` after lower-casing; rename hold **30 days**; expiry **182 days** (6 months) without `renew`; app renews when last renew is **older than 7 days**; event kind **24243**; event freshness **300 s past / 60 s future**; proof-of-work **16 leading zero bits** (NIP-13 `nonce` tag); rate limit **5 claim/rename per hour** per IP and per key; availability lookups **60 per minute per IP**; emergency-wipe `release` timeout **3 s**; availability check debounce **400 ms**; backups kept **14 days**.
- Reach values on the wire and in storage are exactly `all`, `request`, `none`; default `all`.
- Domain: `id.cubechat.tech` (DNS A → 209.38.225.225 already exists). Share link: `https://cubechat.tech/u.html#<name>`.
- Commit subjects are a sentence about the effect (CLAUDE.md); end every commit message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Do not bump the app version or build stamp.
- Before replacing the live `/etc/caddy/Caddyfile`: diff it against the repo copy and back it up; after reload `curl` all of `push.cubechat.tech/health`, `relay.cubechat.tech` and `id.cubechat.tech/health`.

## Review Focus

1. **Card whose embedded Nostr key differs from the signing event's key** — must be refused (403 `card-mismatch`), otherwise anyone could point a name at someone else's identity. Test in Task 3.
2. **A name held after rename is claimed by someone else within 30 days** — must be refused with `taken`, and lookups keep returning the original owner's card. Test in Task 3.
3. **History not loaded yet when a stranger's first internet message arrives** — the request decision must await `messagesController.loaded`, never treat "not loaded" as "I never wrote to them" for a known contact. Test in Task 9.
4. **Server returns a card whose signature was altered** — the phone must reject it and show "not found", never import it. Test in Task 8.
5. **Uppercase or `@`-prefixed input (`@Dima`)** — must be normalised to `dima` on both sides, never produce two different names. Test in Tasks 1 and 7.

## File map

| File | Responsibility |
|---|---|
| `id/package.json`, `id/src/names.js` | Name normalisation and rules (format, reserved, profanity) |
| `id/test/fixtures/name-cases.json` | Shared name cases, read by the Node **and** the Dart tests |
| `id/src/card.js` | Parse + Ed25519-verify `PeerAnnouncement` bytes (v4 and v5) |
| `id/test/fixtures/card.json` | A card minted by Dart, used by Node tests |
| `id/src/events.js` | NIP-01 id/signature check, freshness, NIP-13 difficulty |
| `id/src/registry.js` | SQLite store and the five operations, injectable clock |
| `id/src/server.js` | HTTP routes, rate limits, admin revoke, ban-file reload, sweeps |
| `id/deploy/*` | systemd unit, backup script + timer, README |
| `push/deploy/Caddyfile` | `id.cubechat.tech` block |
| `lib/features/cube_id/domain/cube_name.dart` | Dart twin of `names.js` |
| `lib/features/cube_id/data/cube_id_events.dart` | Build + proof-of-work + sign kind-24243 events |
| `lib/features/cube_id/data/cube_id_client.dart` | HTTP calls to `id.cubechat.tech` |
| `lib/features/cube_id/data/cube_id_controller.dart` | Own name state, claim/rename/release/maintain |
| `lib/features/cube_id/data/known_names_controller.dart` | `pubkeyHex → name` for people found by name |
| `lib/features/cube_id/presentation/cube_id_screen.dart` | Profile → Cube ID screen |
| `lib/features/profile/data/privacy_settings_controller.dart` | `StrangerReach` setting |
| `lib/features/chats/data/message_requests_controller.dart` | Pending / accepted request sets |
| `lib/features/chats/presentation/requests_screen.dart` | Requests drawer |
| `lib/core/transport/messaging_service.dart` | Inbound gate (additive) |
| `docs/legal/*`, landing `public/u.html`, `public/privacy.html` | Legal text and share page |

---

### Task 1: Server scaffold and name rules

**Files:**
- Create: `id/package.json`, `id/src/names.js`, `id/test/names.test.js`, `id/test/fixtures/name-cases.json`, `id/.gitignore`

**Interfaces:**
- Produces: `normalizeName(raw: string): string` (trim, strip one leading `@`, lower-case); `nameProblem(name: string): null | 'invalid' | 'reserved'` (expects a normalised name). Fixture format: `[{"input": string, "name": string, "problem": null|"invalid"|"reserved"}]`.

- [ ] **Step 1: Write the shared fixture**

`id/test/fixtures/name-cases.json`:

```json
[
  {"input": "dima", "name": "dima", "problem": null},
  {"input": "@Dima", "name": "dima", "problem": null},
  {"input": "  DIMA_2026 ", "name": "dima_2026", "problem": null},
  {"input": "ab", "name": "ab", "problem": "invalid"},
  {"input": "a_very_long_name_over_20", "name": "a_very_long_name_over_20", "problem": "invalid"},
  {"input": "dima.k", "name": "dima.k", "problem": "invalid"},
  {"input": "дима", "name": "дима", "problem": "invalid"},
  {"input": "@@dima", "name": "@dima", "problem": "invalid"},
  {"input": "admin", "name": "admin", "problem": "reserved"},
  {"input": "Support", "name": "support", "problem": "reserved"},
  {"input": "cubechat", "name": "cubechat", "problem": "reserved"},
  {"input": "cubechat_team", "name": "cubechat_team", "problem": "reserved"},
  {"input": "bigshit", "name": "bigshit", "problem": "reserved"},
  {"input": "suka_blyat", "name": "suka_blyat", "problem": "reserved"},
  {"input": "pidor123", "name": "pidor123", "problem": "reserved"},
  {"input": "shiitake", "name": "shiitake", "problem": null},
  {"input": "scunthorpe", "name": "scunthorpe", "problem": null},
  {"input": "sukanya", "name": "sukanya", "problem": null},
  {"input": "bass_player", "name": "bass_player", "problem": null}
]
```

- [ ] **Step 2: Package and ignore file**

`id/package.json`:

```json
{
  "name": "cubechat-id",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "description": "Cube ID: @name -> signed contact card.",
  "main": "src/server.js",
  "scripts": { "start": "node src/server.js", "test": "node --test" },
  "engines": { "node": ">=22" },
  "dependencies": { "@noble/curves": "^1.6.0", "@noble/hashes": "^1.5.0" }
}
```

`id/.gitignore`:

```
node_modules/
*.db
*.db-*
.env
```

- [ ] **Step 3: Write the failing test**

`id/test/names.test.js`:

```js
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { nameProblem, normalizeName } from '../src/names.js';

const cases = JSON.parse(readFileSync(new URL('./fixtures/name-cases.json', import.meta.url)));

for (const c of cases) {
  test(`name case ${JSON.stringify(c.input)}`, () => {
    const name = normalizeName(c.input);
    assert.equal(name, c.name);
    assert.equal(nameProblem(name), c.problem);
  });
}
```

- [ ] **Step 4: Run it to see it fail**

Run: `cd id && npm install && node --test`
Expected: FAIL — `Cannot find module '../src/names.js'`.

- [ ] **Step 5: Implement `id/src/names.js`**

```js
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

// Innocent words that contain a stem. Checked by removing them before the
// substring test, so "shiitake" passes and "shiitakeshit" still does not.
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
```

- [ ] **Step 6: Run the tests**

Run: `cd id && node --test`
Expected: PASS, 19 tests.

- [ ] **Step 7: Commit**

```bash
git add id/package.json id/.gitignore id/src/names.js id/test/names.test.js id/test/fixtures/name-cases.json
git commit -m "Give Cube ID one set of name rules both the server and the app can be held to"
```

(Do not commit `id/package-lock.json` unless `push/` commits its own — it does not; leave it untracked.)

---

### Task 2: Card parsing on the server, pinned to a card Dart actually mints

**Files:**
- Create: `test/cube_id_card_fixture_test.dart`, `id/test/fixtures/card.json`, `id/src/card.js`, `id/test/card.test.js`

**Interfaces:**
- Consumes: Dart `PeerAnnouncement` (`lib/core/transport/announcement.dart`): layout `[ver:1][x25519:32][ed25519:32][prekey:32][nostr:32][nlen:1][nick:nlen][avatar:32 only if ver==0x05][sig:64]`, signature over everything before `sig`; versions `0x05` and `0x04`.
- Produces: `parseCard(bytes: Uint8Array): { version, x25519Hex, ed25519Hex, prekeyHex, nostrHex, nickname }` — throws `Error` with `.code = 'card-invalid'` on any layout or signature failure. Fixture `id/test/fixtures/card.json`: `{"cardB64": string, "nostrHex": string, "nickname": string}`.

- [ ] **Step 1: Write the Dart fixture test (it also writes the fixture once)**

`test/cube_id_card_fixture_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cubechat/core/transport/announcement.dart';
import 'package:flutter_test/flutter_test.dart';

/// The card the Cube ID server's tests parse. Minted here so the server is
/// held to the bytes the app really signs, not to a paraphrase of the layout.
/// Regenerate with `CUBE_ID_WRITE_FIXTURE=1 flutter test test/cube_id_card_fixture_test.dart`.
void main() {
  const path = 'id/test/fixtures/card.json';

  test('the Cube ID card fixture is a card this build accepts', () async {
    if (Platform.environment['CUBE_ID_WRITE_FIXTURE'] == '1') {
      final sign = await Ed25519().newKeyPair();
      final signData = await sign.extract();
      final ann = PeerAnnouncement(
        pubkey: Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
        signPubkey: Uint8List.fromList((await sign.extractPublicKey()).bytes),
        signedPrekeyPub: Uint8List.fromList(List<int>.generate(32, (i) => 100 + i)),
        nostrPubkey: Uint8List.fromList(List<int>.generate(32, (i) => 200 - i)),
        nickname: 'Дмитро',
      );
      final bytes = await ann.sign(signData);
      File(path).writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
        'cardB64': base64Encode(bytes),
        'nostrHex': ann.nostrPubkey
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
        'nickname': ann.nickname,
      }));
    }
    final fixture =
        jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    final decoded = await PeerAnnouncement.verifyAndDecode(
      base64Decode(fixture['cardB64'] as String),
    );
    expect(decoded.nickname, fixture['nickname']);
  });
}
```

- [ ] **Step 2: Mint the fixture and confirm the Dart side accepts it**

Run: `CUBE_ID_WRITE_FIXTURE=1 flutter test test/cube_id_card_fixture_test.dart`, then `flutter test test/cube_id_card_fixture_test.dart`
Expected: both PASS; `id/test/fixtures/card.json` exists.

- [ ] **Step 3: Write the failing Node test**

`id/test/card.test.js`:

```js
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { parseCard } from '../src/card.js';

const fixture = JSON.parse(readFileSync(new URL('./fixtures/card.json', import.meta.url)));
const bytes = () => new Uint8Array(Buffer.from(fixture.cardB64, 'base64'));

test('a card minted by the app parses with its keys and nickname', () => {
  const card = parseCard(bytes());
  assert.equal(card.version, 5);
  assert.equal(card.nostrHex, fixture.nostrHex);
  assert.equal(card.nickname, fixture.nickname);
});

test('one flipped byte anywhere before the signature is refused', () => {
  for (const at of [0, 5, 40, 100, 130, 135]) {
    const b = bytes();
    b[at] ^= 0x01;
    assert.throws(() => parseCard(b), { code: 'card-invalid' });
  }
});

test('truncated and empty cards are refused', () => {
  assert.throws(() => parseCard(new Uint8Array(0)), { code: 'card-invalid' });
  assert.throws(() => parseCard(bytes().slice(0, 100)), { code: 'card-invalid' });
});
```

- [ ] **Step 4: Run it to see it fail**

Run: `cd id && node --test test/card.test.js`
Expected: FAIL — module not found.

- [ ] **Step 5: Implement `id/src/card.js`**

```js
// Reads a PeerAnnouncement exactly as lib/core/transport/announcement.dart
// writes it, and checks its Ed25519 signature. The registry never trusts a
// card it has not verified, and the phone verifies it again on lookup.

import { createPublicKey, verify } from 'node:crypto';

const VERSION = 0x05;
const VERSION_NO_AVATAR = 0x04;
const KEY = 32;
const SIG = 64;
const AVATAR = 32;

function invalid(why) {
  const error = new Error(`card: ${why}`);
  error.code = 'card-invalid';
  return error;
}

const hex = (b) => Buffer.from(b).toString('hex');

export function parseCard(bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.length < 1 + KEY * 4 + 1 + SIG) {
    throw invalid('truncated');
  }
  const version = bytes[0];
  if (version !== VERSION && version !== VERSION_NO_AVATAR) throw invalid('version');
  let c = 1;
  const x25519 = bytes.subarray(c, (c += KEY));
  const ed25519 = bytes.subarray(c, (c += KEY));
  const prekey = bytes.subarray(c, (c += KEY));
  const nostr = bytes.subarray(c, (c += KEY));
  const nlen = bytes[c++];
  const avatarBytes = version === VERSION ? AVATAR : 0;
  if (bytes.length !== c + nlen + avatarBytes + SIG) throw invalid('length');
  const nickname = Buffer.from(bytes.subarray(c, c + nlen)).toString('utf8');
  c += nlen + avatarBytes;
  const body = bytes.subarray(0, c);
  const sig = bytes.subarray(c, c + SIG);
  let ok = false;
  try {
    const key = createPublicKey({
      key: { kty: 'OKP', crv: 'Ed25519', x: Buffer.from(ed25519).toString('base64url') },
      format: 'jwk',
    });
    ok = verify(null, body, key, sig);
  } catch {
    ok = false;
  }
  if (!ok) throw invalid('signature');
  return {
    version,
    x25519Hex: hex(x25519),
    ed25519Hex: hex(ed25519),
    prekeyHex: hex(prekey),
    nostrHex: hex(nostr),
    nickname,
  };
}
```

Note: `bytes.length !== …` (exact length) is stricter than Dart's `<` check on purpose — the registry stores the bytes and must not store trailing junk.

- [ ] **Step 6: Run the tests**

Run: `cd id && node --test`
Expected: PASS (names + card).

- [ ] **Step 7: Commit**

```bash
git add test/cube_id_card_fixture_test.dart id/test/fixtures/card.json id/src/card.js id/test/card.test.js
git commit -m "Let the Cube ID server read the same signed card the app puts in a QR code"
```

---

### Task 3: Signed events and the registry

**Files:**
- Create: `id/src/events.js`, `id/src/registry.js`, `id/test/registry.test.js`, `id/test/helpers.js`

**Interfaces:**
- Consumes: `parseCard` (Task 2), `normalizeName`/`nameProblem` (Task 1).
- Produces:
  - `events.js`: `verifyEvent(event): boolean` (NIP-01 id + BIP-340 sig); `difficulty(idHex): number` (leading zero bits); constants `KIND = 24243`, `POW_BITS = 16`, `MAX_PAST = 300`, `MAX_FUTURE = 60`.
  - `registry.js`: `openRegistry({ path = ':memory:', now = () => Date.now() }) → registry` with
    - `apply(event): { status: number, body: object }` — handles `op` ∈ `claim | rename | update | renew | release`;
    - `lookup(name): { name, card: Uint8Array, reach } | null` (honours `held`, hides `reach = 'none'` and revoked);
    - `availability(name): { available: boolean, reason?: 'invalid'|'reserved'|'taken' }`;
    - `revoke({ name?, npub?, reason }): number` (names revoked);
    - `revokeNpubs(set: Set<string>): number`;
    - `sweep(): { expired: number, unheld: number }`;
    - `count(): number`; `close()`.
  - Status codes: 200 ok; 400 `bad-request`; 401 `bad-signature` | `stale`; 403 `card-mismatch` | `card-invalid` | `pow` | `banned`; 404 `no-name`; 409 `taken` | `reserved` | `invalid` | `has-name`; 429 is decided in the server, not here.
  - `helpers.js` (tests only): `signedOp(content, { key = '01'.repeat(32), createdAt, powBits = 16 })`, `cardFor(nostrHex)` returning card bytes signed with a fresh Ed25519 key.

- [ ] **Step 1: Test helpers**

`id/test/helpers.js`:

```js
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { schnorr } from '@noble/curves/secp256k1';

export const T0 = 1_790_000_000; // seconds

export function nostrPub(key) {
  return Buffer.from(schnorr.getPublicKey(key)).toString('hex');
}

// A v5 card in the app's layout, signed with a fresh Ed25519 key.
export function cardFor(nostrHex, nickname = 'Dima') {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const edRaw = Buffer.from(publicKey.export({ format: 'jwk' }).x, 'base64url');
  const nick = Buffer.from(nickname, 'utf8');
  const body = Buffer.concat([
    Buffer.from([0x05]),
    Buffer.alloc(32, 1), edRaw, Buffer.alloc(32, 3),
    Buffer.from(nostrHex, 'hex'),
    Buffer.from([nick.length]), nick, Buffer.alloc(32, 0),
  ]);
  return new Uint8Array(Buffer.concat([body, sign(null, body, privateKey)]));
}

function idOf(e) {
  return createHash('sha256')
    .update(JSON.stringify([0, e.pubkey, e.created_at, e.kind, e.tags, e.content]))
    .digest('hex');
}

function zeroBits(hex) {
  let n = 0;
  for (const ch of hex) {
    const v = parseInt(ch, 16);
    if (v === 0) { n += 4; continue; }
    n += Math.clz32(v) - 28;
    break;
  }
  return n;
}

export function signedOp(content, { key = '01'.repeat(32), createdAt = T0, powBits = 16 } = {}) {
  const pubkey = nostrPub(key);
  const e = { pubkey, created_at: createdAt, kind: 24243, tags: [], content: JSON.stringify(content) };
  if (powBits > 0) {
    for (let nonce = 0; ; nonce++) {
      e.tags = [['nonce', String(nonce), String(powBits)]];
      e.id = idOf(e);
      if (zeroBits(e.id) >= powBits) break;
    }
  } else {
    e.id = idOf(e);
  }
  e.sig = Buffer.from(schnorr.sign(e.id, key)).toString('hex');
  return e;
}

export const b64u = (bytes) => Buffer.from(bytes).toString('base64url');
```

- [ ] **Step 2: Write the failing registry tests**

`id/test/registry.test.js`:

```js
import assert from 'node:assert/strict';
import test from 'node:test';
import { openRegistry } from '../src/registry.js';
import { T0, b64u, cardFor, nostrPub, signedOp } from './helpers.js';

const A = '01'.repeat(32);
const B = '02'.repeat(32);
const DAY = 86_400;

function reg(startSeconds = T0) {
  let now = startSeconds;
  const r = openRegistry({ now: () => now * 1000 });
  return { r, advance: (s) => { now += s; }, at: () => now };
}

const claim = (key, name, extra = {}) =>
  signedOp({ op: 'claim', name, card: b64u(cardFor(nostrPub(key))) }, { key, ...extra });

test('claim, then lookup returns the same card bytes', () => {
  const { r } = reg();
  const event = claim(A, 'Dima');
  assert.equal(r.apply(event).status, 200);
  const found = r.lookup('dima');
  assert.equal(found.name, 'dima');
  assert.equal(found.reach, 'all');
  assert.equal(b64u(found.card), JSON.parse(event.content).card);
});

test('a card whose Nostr key is not the signer is refused', () => {
  const { r } = reg();
  const event = signedOp({ op: 'claim', name: 'dima', card: b64u(cardFor(nostrPub(B))) }, { key: A });
  assert.deepEqual(r.apply(event), { status: 403, body: { error: 'card-mismatch' } });
});

test('claim without enough proof-of-work is refused', () => {
  const { r } = reg();
  assert.equal(r.apply(claim(A, 'dima', { powBits: 0 })).body.error, 'pow');
});

test('stale, future and replayed events are refused', () => {
  const { r } = reg();
  assert.equal(r.apply(claim(A, 'old', { createdAt: T0 - 301 })).body.error, 'stale');
  assert.equal(r.apply(claim(A, 'new', { createdAt: T0 + 61 })).body.error, 'stale');
  const e = claim(A, 'once');
  assert.equal(r.apply(e).status, 200);
  assert.equal(r.apply(e).body.error, 'stale');
});

test('names are unique, one per key, and rules apply', () => {
  const { r } = reg();
  assert.equal(r.apply(claim(A, 'dima')).status, 200);
  assert.equal(r.apply(claim(B, 'DIMA')).body.error, 'taken');
  assert.equal(r.apply(claim(A, 'other', { createdAt: T0 + 1 })).body.error, 'has-name');
  assert.equal(r.apply(claim(B, 'admin')).body.error, 'reserved');
  assert.equal(r.apply(claim(B, 'x')).body.error, 'invalid');
});

test('rename holds the old name for 30 days for the owner only', () => {
  const { r, advance } = reg();
  r.apply(claim(A, 'dima'));
  const card = b64u(cardFor(nostrPub(A)));
  assert.equal(r.apply(signedOp({ op: 'rename', name: 'dmytro', card }, { key: A, createdAt: T0 + 1 })).status, 200);
  assert.equal(r.lookup('dima').name, 'dima');
  assert.equal(r.lookup('dmytro').name, 'dmytro');
  advance(29 * DAY);
  assert.equal(r.apply(claim(B, 'dima', { createdAt: T0 + 29 * DAY })).body.error, 'taken');
  advance(2 * DAY);
  r.sweep();
  assert.equal(r.lookup('dima'), null);
  assert.equal(r.apply(claim(B, 'dima', { createdAt: T0 + 31 * DAY })).status, 200);
});

test('update replaces the card and the reach; none hides the name', () => {
  const { r } = reg();
  r.apply(claim(A, 'dima'));
  const card = b64u(cardFor(nostrPub(A), 'Dmytro'));
  assert.equal(r.apply(signedOp({ op: 'update', card, reach: 'none' }, { key: A, createdAt: T0 + 1, powBits: 0 })).status, 200);
  assert.equal(r.lookup('dima'), null);
  assert.equal(r.availability('dima').reason, 'taken');
  assert.equal(r.apply(signedOp({ op: 'update', card, reach: 'maybe' }, { key: A, createdAt: T0 + 2, powBits: 0 })).body.error, 'bad-request');
});

test('no renew for 182 days frees the name; renew keeps it', () => {
  const { r, advance } = reg();
  r.apply(claim(A, 'dima'));
  r.apply(claim(B, 'olga'));
  advance(100 * DAY);
  assert.equal(r.apply(signedOp({ op: 'renew' }, { key: A, createdAt: T0 + 100 * DAY, powBits: 0 })).status, 200);
  advance(83 * DAY);
  assert.deepEqual(r.sweep(), { expired: 1, unheld: 0 });
  assert.notEqual(r.lookup('dima'), null);
  assert.equal(r.lookup('olga'), null);
});

test('release frees at once; revoke frees and blocks the name', () => {
  const { r } = reg();
  r.apply(claim(A, 'dima'));
  assert.equal(r.apply(signedOp({ op: 'release' }, { key: A, createdAt: T0 + 1, powBits: 0 })).status, 200);
  assert.equal(r.availability('dima').available, true);
  r.apply(claim(B, 'dima', { createdAt: T0 + 2 }));
  assert.equal(r.revoke({ name: 'dima', reason: 'offensive' }), 1);
  assert.equal(r.lookup('dima'), null);
  assert.equal(r.availability('dima').reason, 'reserved');
  assert.equal(r.revokeNpubs(new Set([nostrPub(A)])), 0);
});

test('operations on a key without a name are 404', () => {
  const { r } = reg();
  assert.equal(r.apply(signedOp({ op: 'renew' }, { key: A, powBits: 0 })).status, 404);
});
```

- [ ] **Step 3: Run it to see it fail**

Run: `cd id && node --test test/registry.test.js`
Expected: FAIL — module not found.

- [ ] **Step 4: Implement `id/src/events.js`**

```js
import { schnorr } from '@noble/curves/secp256k1';
import { sha256 } from '@noble/hashes/sha256';
import { bytesToHex, utf8ToBytes } from '@noble/hashes/utils';

export const KIND = 24243;
export const POW_BITS = 16;
export const MAX_PAST = 300;
export const MAX_FUTURE = 60;

// Same checks as verifyEvent in push/src/index.js: the id is the hash of the
// canonical form and the signature verifies against the pubkey in it.
export function verifyEvent(event) {
  if (
    typeof event?.pubkey !== 'string' || typeof event?.id !== 'string' ||
    typeof event?.sig !== 'string' || typeof event?.content !== 'string' ||
    typeof event?.created_at !== 'number' || !Array.isArray(event?.tags) ||
    event?.kind !== KIND
  ) return false;
  if (!/^[0-9a-f]{64}$/.test(event.pubkey) || !/^[0-9a-f]{64}$/.test(event.id) ||
      !/^[0-9a-f]{128}$/.test(event.sig)) return false;
  const canonical = JSON.stringify([0, event.pubkey, event.created_at, event.kind, event.tags, event.content]);
  if (bytesToHex(sha256(utf8ToBytes(canonical))) !== event.id) return false;
  try {
    return schnorr.verify(event.sig, event.id, event.pubkey);
  } catch {
    return false;
  }
}

// NIP-13: the number of leading zero bits of the event id.
export function difficulty(idHex) {
  let bits = 0;
  for (const ch of idHex) {
    const v = parseInt(ch, 16);
    if (v === 0) { bits += 4; continue; }
    return bits + Math.clz32(v) - 28;
  }
  return bits;
}
```

- [ ] **Step 5: Implement `id/src/registry.js`**

```js
// Cube ID's whole state: which name points at which signed card.
//
// Every change arrives as a Nostr event signed by the owner, and the card must
// carry that same Nostr key — so the database can be restored from a backup and
// any forged row is visible, because it would not verify.

import { DatabaseSync } from 'node:sqlite';
import { parseCard } from './card.js';
import { MAX_FUTURE, MAX_PAST, POW_BITS, difficulty, verifyEvent } from './events.js';
import { nameProblem, normalizeName } from './names.js';

const DAY = 86_400;
export const HOLD_SECONDS = 30 * DAY;
export const EXPIRE_SECONDS = 182 * DAY;
const REACH = new Set(['all', 'request', 'none']);
const OPS = new Set(['claim', 'rename', 'update', 'renew', 'release']);

const fail = (status, error) => ({ status, body: { error } });
const ok = (body = { ok: true }) => ({ status: 200, body });

export function openRegistry({ path = ':memory:', now = () => Date.now() } = {}) {
  const db = new DatabaseSync(path);
  db.exec(`
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS names (
      name TEXT PRIMARY KEY, nostr_pub TEXT NOT NULL UNIQUE, card BLOB NOT NULL,
      reach TEXT NOT NULL DEFAULT 'all', created_at INTEGER NOT NULL, renewed_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS held (
      name TEXT PRIMARY KEY, nostr_pub TEXT NOT NULL, until INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS revoked (
      name TEXT PRIMARY KEY, reason TEXT, at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS seen (
      id TEXT PRIMARY KEY, at INTEGER NOT NULL);
  `);
  const seconds = () => Math.floor(now() / 1000);
  const q = {
    byName: db.prepare('SELECT * FROM names WHERE name = ?'),
    byPub: db.prepare('SELECT * FROM names WHERE nostr_pub = ?'),
    held: db.prepare('SELECT * FROM held WHERE name = ?'),
    revoked: db.prepare('SELECT 1 FROM revoked WHERE name = ?'),
    seen: db.prepare('SELECT 1 FROM seen WHERE id = ?'),
    remember: db.prepare('INSERT INTO seen (id, at) VALUES (?, ?)'),
    insert: db.prepare('INSERT INTO names (name, nostr_pub, card, reach, created_at, renewed_at) VALUES (?, ?, ?, ?, ?, ?)'),
    del: db.prepare('DELETE FROM names WHERE nostr_pub = ?'),
    hold: db.prepare('INSERT OR REPLACE INTO held (name, nostr_pub, until) VALUES (?, ?, ?)'),
    unholdOwn: db.prepare('DELETE FROM held WHERE nostr_pub = ?'),
    update: db.prepare('UPDATE names SET card = ?, reach = ? WHERE nostr_pub = ?'),
    renew: db.prepare('UPDATE names SET renewed_at = ? WHERE nostr_pub = ?'),
  };

  function blocked(name, pub) {
    const problem = nameProblem(name);
    if (problem) return problem;
    if (q.revoked.get(name)) return 'reserved';
    const owner = q.byName.get(name);
    if (owner && owner.nostr_pub !== pub) return 'taken';
    const held = q.held.get(name);
    if (held && held.nostr_pub !== pub && held.until > seconds()) return 'taken';
    return null;
  }

  function verifiedCard(content, pub) {
    let card;
    try {
      card = new Uint8Array(Buffer.from(String(content.card ?? ''), 'base64url'));
      const parsed = parseCard(card);
      if (parsed.nostrHex !== pub) return { error: fail(403, 'card-mismatch') };
    } catch {
      return { error: fail(403, 'card-invalid') };
    }
    return { card };
  }

  function apply(event) {
    if (!verifyEvent(event)) return fail(401, 'bad-signature');
    const t = seconds();
    if (event.created_at < t - MAX_PAST || event.created_at > t + MAX_FUTURE) return fail(401, 'stale');
    if (q.seen.get(event.id)) return fail(401, 'stale');
    let content;
    try {
      content = JSON.parse(event.content);
    } catch {
      return fail(400, 'bad-request');
    }
    if (!OPS.has(content?.op)) return fail(400, 'bad-request');
    const pub = event.pubkey;
    const mine = q.byPub.get(pub);
    const op = content.op;

    if ((op === 'claim' || op === 'rename') && difficulty(event.id) < POW_BITS) return fail(403, 'pow');
    if (op !== 'claim' && !mine) return fail(404, 'no-name');
    if (op === 'claim' && mine) return fail(409, 'has-name');

    let result;
    if (op === 'claim' || op === 'rename') {
      const name = normalizeName(content.name);
      const why = blocked(name, pub);
      if (why) return fail(409, why);
      const { card, error } = verifiedCard(content, pub);
      if (error) return error;
      db.exec('BEGIN');
      try {
        if (mine) {
          q.del.run(pub);
          if (mine.name !== name) q.hold.run(mine.name, pub, t + HOLD_SECONDS);
        }
        q.insert.run(name, pub, card, mine?.reach ?? 'all', mine?.created_at ?? t, t);
        db.exec('COMMIT');
      } catch (e) {
        db.exec('ROLLBACK');
        throw e;
      }
      result = ok({ name });
    } else if (op === 'update') {
      const reach = content.reach ?? mine.reach;
      if (!REACH.has(reach)) return fail(400, 'bad-request');
      const { card, error } = content.card ? verifiedCard(content, pub) : { card: mine.card };
      if (error) return error;
      q.update.run(card, reach, pub);
      result = ok({ name: mine.name });
    } else if (op === 'renew') {
      q.renew.run(t, pub);
      result = ok({ name: mine.name });
    } else {
      q.del.run(pub);
      q.unholdOwn.run(pub);
      result = ok();
    }
    q.remember.run(event.id, t);
    return result;
  }

  function lookup(raw) {
    const name = normalizeName(raw);
    if (nameProblem(name) === 'invalid' || q.revoked.get(name)) return null;
    let row = q.byName.get(name);
    if (!row) {
      const held = q.held.get(name);
      if (held && held.until > seconds()) row = q.byPub.get(held.nostr_pub);
    }
    if (!row || row.reach === 'none') return null;
    return { name, card: new Uint8Array(row.card), reach: row.reach };
  }

  function availability(raw) {
    const name = normalizeName(raw);
    const problem = nameProblem(name);
    if (problem) return { available: false, reason: problem };
    if (q.revoked.get(name)) return { available: false, reason: 'reserved' };
    if (q.byName.get(name)) return { available: false, reason: 'taken' };
    const held = q.held.get(name);
    if (held && held.until > seconds()) return { available: false, reason: 'taken' };
    return { available: true };
  }

  function revoke({ name, npub, reason = '' }) {
    let n = 0;
    const rows = name ? [q.byName.get(normalizeName(name))] : [q.byPub.get(String(npub).toLowerCase())];
    for (const row of rows) {
      if (!row) continue;
      q.del.run(row.nostr_pub);
      db.prepare('INSERT OR REPLACE INTO revoked (name, reason, at) VALUES (?, ?, ?)').run(row.name, reason, seconds());
      n++;
    }
    if (name && n === 0) {
      db.prepare('INSERT OR REPLACE INTO revoked (name, reason, at) VALUES (?, ?, ?)').run(normalizeName(name), reason, seconds());
    }
    return n;
  }

  function revokeNpubs(npubs) {
    let n = 0;
    for (const npub of npubs) n += revoke({ npub, reason: 'banned' });
    return n;
  }

  function sweep() {
    const t = seconds();
    const expired = db.prepare('DELETE FROM names WHERE renewed_at < ?').run(t - EXPIRE_SECONDS).changes;
    const unheld = db.prepare('DELETE FROM held WHERE until <= ?').run(t).changes;
    db.prepare('DELETE FROM seen WHERE at < ?').run(t - MAX_PAST - MAX_FUTURE);
    return { expired: Number(expired), unheld: Number(unheld) };
  }

  return {
    apply, lookup, availability, revoke, revokeNpubs, sweep,
    count: () => Number(db.prepare('SELECT COUNT(*) AS n FROM names').get().n),
    close: () => db.close(),
  };
}
```

- [ ] **Step 6: Run the tests**

Run: `cd id && node --test`
Expected: PASS. (Node 22 prints an `ExperimentalWarning` for `node:sqlite`; that is expected and not a failure.)

- [ ] **Step 7: Commit**

```bash
git add id/src/events.js id/src/registry.js id/test/registry.test.js id/test/helpers.js
git commit -m "Keep one @name per key, held 30 days after a rename, and only ever pointing at the signer's own card"
```

---

### Task 4: HTTP server, rate limits, bans and admin revoke

**Files:**
- Create: `id/src/server.js`, `id/test/server.test.js`

**Interfaces:**
- Consumes: `openRegistry` (Task 3).
- Produces: `createIdServer({ registry, adminToken, bannedPath, now }) → http.Server` (not listening) and a `main()` that runs when the file is executed directly. Routes:
  - `POST /v1/op` body = the event JSON → `registry.apply`; 429 `rate` when the IP or the key exceeds 5 `claim`/`rename` per hour.
  - `GET /v1/card/:name` → 200 `{name, card (base64url), reach}` or 404 `{error:'not-found'}`.
  - `GET /v1/available/:name` → 200 `{available, reason?}`; 429 over 60/min per IP.
  - `GET /.well-known/nostr.json?name=x` → 200 `{names:{x: hex}}` or `{names:{}}`; header `Access-Control-Allow-Origin: *` (NIP-05 requires it).
  - `GET /health` → `{ok:true, version, names}`.
  - `POST /admin/revoke` `{name?|npub?, reason}` with `Authorization: Bearer <adminToken>`, only from `127.0.0.1`/`::1` → `{revoked:n}`; else 403.
  - Every 60 s: reload `bannedPath` (push's `banned.json`, field `npubs`), `revokeNpubs`; every hour: `sweep()`.
- Env (read in `main`): `PORT` (default 8090), `DB_PATH` (default `./names.db`), `ADMIN_TOKEN`, `BANNED_PATH` (default `/opt/cubechat-push/banned.json`). The client IP is taken from `X-Forwarded-For`'s first entry **only** when the socket peer is loopback (Caddy), else the socket address.

- [ ] **Step 1: Write the failing test**

`id/test/server.test.js`:

```js
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { openRegistry } from '../src/registry.js';
import { createIdServer } from '../src/server.js';
import { T0, b64u, cardFor, nostrPub, signedOp } from './helpers.js';

const A = '01'.repeat(32);

async function start() {
  const dir = mkdtempSync(join(tmpdir(), 'cubeid-'));
  const bannedPath = join(dir, 'banned.json');
  writeFileSync(bannedPath, JSON.stringify({ npubs: [] }));
  const registry = openRegistry({ now: () => T0 * 1000 });
  const server = createIdServer({ registry, adminToken: 'secret', bannedPath, now: () => T0 * 1000 });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}`;
  return { base, server, registry, bannedPath };
}

const post = (url, body, headers = {}) =>
  fetch(url, { method: 'POST', body: JSON.stringify(body), headers: { 'content-type': 'application/json', ...headers } });

test('claim over HTTP, then card, NIP-05 and availability agree', async (t) => {
  const { base, server } = await start();
  t.after(() => server.close());
  const card = b64u(cardFor(nostrPub(A)));
  const r = await post(`${base}/v1/op`, signedOp({ op: 'claim', name: 'dima', card }, { key: A }));
  assert.equal(r.status, 200);
  const got = await (await fetch(`${base}/v1/card/Dima`)).json();
  assert.equal(got.card, card);
  const nip05 = await fetch(`${base}/.well-known/nostr.json?name=dima`);
  assert.equal(nip05.headers.get('access-control-allow-origin'), '*');
  assert.deepEqual(await nip05.json(), { names: { dima: nostrPub(A) } });
  assert.deepEqual(await (await fetch(`${base}/v1/available/dima`)).json(), { available: false, reason: 'taken' });
  assert.equal((await fetch(`${base}/v1/card/nobody`)).status, 404);
});

test('more than five claims an hour from one address is 429', async (t) => {
  const { base, server } = await start();
  t.after(() => server.close());
  const statuses = [];
  for (let i = 0; i < 6; i++) {
    const key = String(i + 10).padStart(2, '0').repeat(32);
    const card = b64u(cardFor(nostrPub(key)));
    statuses.push((await post(`${base}/v1/op`, signedOp({ op: 'claim', name: `user_${i}`, card }, { key }))).status);
  }
  assert.deepEqual(statuses, [200, 200, 200, 200, 200, 429]);
});

test('admin revoke needs the token; a banned key loses its name', async (t) => {
  const { base, server, registry, bannedPath } = await start();
  t.after(() => server.close());
  const card = b64u(cardFor(nostrPub(A)));
  await post(`${base}/v1/op`, signedOp({ op: 'claim', name: 'dima', card }, { key: A }));
  assert.equal((await post(`${base}/admin/revoke`, { name: 'dima' })).status, 403);
  writeFileSync(bannedPath, JSON.stringify({ npubs: [nostrPub(A)] }));
  await server.reloadBans();
  assert.equal(registry.lookup('dima'), null);
});

test('health reports the count', async (t) => {
  const { base, server } = await start();
  t.after(() => server.close());
  const health = await (await fetch(`${base}/health`)).json();
  assert.equal(health.ok, true);
  assert.equal(health.names, 0);
});
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd id && node --test test/server.test.js`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `id/src/server.js`**

```js
// https://id.cubechat.tech — Cube ID's only door. See
// docs/superpowers/specs/2026-09-29-cube-id-names-design.md.

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { timingSafeEqual } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { openRegistry } from './registry.js';
import { normalizeName } from './names.js';

/// What /health reports. Bump it in the same commit as any change here.
export const VERSION = '2026-09-29-names';

function limiter(max, windowMs, now) {
  const hits = new Map();
  return (key) => {
    const t = now();
    const list = (hits.get(key) ?? []).filter((x) => x > t - windowMs);
    if (list.length >= max) { hits.set(key, list); return false; }
    list.push(t);
    hits.set(key, list);
    if (hits.size > 50_000) for (const [k, v] of hits) if (!v.some((x) => x > t - windowMs)) hits.delete(k);
    return true;
  };
}

function send(res, status, body, headers = {}) {
  const text = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', ...headers });
  res.end(text);
}

function readBody(req, limit = 16 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) { reject(new Error('too-large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

const loopback = (addr) => addr === '127.0.0.1' || addr === '::1' || addr === '::ffff:127.0.0.1';

function clientIp(req) {
  const peer = req.socket.remoteAddress ?? '';
  if (loopback(peer)) {
    const fwd = String(req.headers['x-forwarded-for'] ?? '').split(',')[0].trim();
    if (fwd) return fwd;
  }
  return peer;
}

function tokenOk(header, expected) {
  if (!expected) return false;
  const given = Buffer.from(String(header ?? '').replace(/^Bearer /, ''));
  const want = Buffer.from(expected);
  return given.length === want.length && timingSafeEqual(given, want);
}

export function createIdServer({ registry, adminToken, bannedPath, now = () => Date.now() }) {
  const opsByIp = limiter(5, 3_600_000, now);
  const opsByKey = limiter(5, 3_600_000, now);
  const lookupsByIp = limiter(60, 60_000, now);

  const server = createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const ip = clientIp(req);
    try {
      if (req.method === 'GET' && url.pathname === '/health') {
        return send(res, 200, { ok: true, version: VERSION, names: registry.count() });
      }
      if (req.method === 'GET' && url.pathname === '/.well-known/nostr.json') {
        const name = normalizeName(url.searchParams.get('name') ?? '');
        const found = registry.lookup(name);
        const names = {};
        if (found) {
          const { parseCard } = await import('./card.js');
          names[found.name] = parseCard(found.card).nostrHex;
        }
        return send(res, 200, { names }, { 'access-control-allow-origin': '*' });
      }
      const card = url.pathname.match(/^\/v1\/card\/([^/]+)$/);
      if (req.method === 'GET' && card) {
        if (!lookupsByIp(ip)) return send(res, 429, { error: 'rate' });
        const found = registry.lookup(decodeURIComponent(card[1]));
        if (!found) return send(res, 404, { error: 'not-found' });
        return send(res, 200, { name: found.name, card: Buffer.from(found.card).toString('base64url'), reach: found.reach });
      }
      const avail = url.pathname.match(/^\/v1\/available\/([^/]+)$/);
      if (req.method === 'GET' && avail) {
        if (!lookupsByIp(ip)) return send(res, 429, { error: 'rate' });
        return send(res, 200, registry.availability(decodeURIComponent(avail[1])));
      }
      if (req.method === 'POST' && url.pathname === '/v1/op') {
        let event;
        try {
          event = JSON.parse(await readBody(req));
        } catch {
          return send(res, 400, { error: 'bad-request' });
        }
        let op = '';
        try { op = JSON.parse(event?.content ?? '{}')?.op ?? ''; } catch { /* apply() reports it */ }
        if (op === 'claim' || op === 'rename') {
          if (!opsByIp(ip) || !opsByKey(String(event?.pubkey))) return send(res, 429, { error: 'rate' });
        }
        const result = registry.apply(event);
        return send(res, result.status, result.body);
      }
      if (req.method === 'POST' && url.pathname === '/admin/revoke') {
        if (!loopback(req.socket.remoteAddress ?? '') || !tokenOk(req.headers.authorization, adminToken)) {
          return send(res, 403, { error: 'forbidden' });
        }
        const body = JSON.parse(await readBody(req) || '{}');
        return send(res, 200, { revoked: registry.revoke(body) });
      }
      return send(res, 404, { error: 'not-found' });
    } catch (e) {
      console.error('[id] request failed', e);
      return send(res, 500, { error: 'internal' });
    }
  });

  server.reloadBans = async () => {
    if (!bannedPath) return 0;
    try {
      const parsed = JSON.parse(await readFile(bannedPath, 'utf8'));
      const npubs = new Set((parsed.npubs ?? []).map((x) => String(x).toLowerCase()));
      const n = registry.revokeNpubs(npubs);
      if (n) console.log(`[id] revoked ${n} name(s) of banned keys`);
      return n;
    } catch {
      return 0;
    }
  };
  return server;
}

async function main() {
  const registry = openRegistry({ path: process.env.DB_PATH || './names.db' });
  const server = createIdServer({
    registry,
    adminToken: process.env.ADMIN_TOKEN || '',
    bannedPath: process.env.BANNED_PATH || '/opt/cubechat-push/banned.json',
  });
  await server.reloadBans();
  setInterval(() => void server.reloadBans(), 60_000).unref();
  setInterval(() => {
    const swept = registry.sweep();
    if (swept.expired || swept.unheld) console.log('[id] sweep', swept);
  }, 3_600_000).unref();
  const port = Number(process.env.PORT || 8090);
  server.listen(port, '127.0.0.1', () => console.log(`[id] ${VERSION} on 127.0.0.1:${port}, ${registry.count()} names`));
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) void main();
```

- [ ] **Step 4: Run the tests**

Run: `cd id && node --test`
Expected: PASS (all four files).

- [ ] **Step 5: Commit**

```bash
git add id/src/server.js id/test/server.test.js
git commit -m "Serve Cube ID over HTTP: cards by name, NIP-05, a rate limit, and bans that take the name away"
```

---

### Task 5: Deploy `cubechat-id` on the droplet

**Files:**
- Create: `id/deploy/cubechat-id.service`, `id/deploy/backup-names.sh`, `id/deploy/cubechat-id-backup.service`, `id/deploy/cubechat-id-backup.timer`, `id/deploy/README.md`
- Modify: `push/deploy/Caddyfile` (add the `id.cubechat.tech` block)

**Interfaces:**
- Consumes: `id/src/server.js` `main()` env contract (Task 4).
- Produces: `https://id.cubechat.tech/health` answering `{"ok":true,"version":"2026-09-29-names",...}`.

This task changes a live server. **Ask the owner before Step 4** ("Деплою cubechat-id на droplet и добавляю блок в Caddy — да?") and do not proceed without a yes.

- [ ] **Step 1: systemd unit**

`id/deploy/cubechat-id.service`:

```ini
[Unit]
Description=cubechat Cube ID (@name -> signed card)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=cubechat
WorkingDirectory=/opt/cubechat-id
EnvironmentFile=/opt/cubechat-id/.env
ExecStart=/usr/bin/node src/server.js
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/cubechat-id
ReadOnlyPaths=/opt/cubechat-push/banned.json

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Backup script and timer**

`id/deploy/backup-names.sh`:

```sh
#!/bin/sh
# Daily consistent copy of the name registry, kept 14 days.
set -eu
dir=/root/backups/cubechat-id
mkdir -p "$dir"
sqlite3 /opt/cubechat-id/names.db ".backup '$dir/names-$(date +%F).db'"
find "$dir" -name 'names-*.db' -mtime +14 -delete
```

`id/deploy/cubechat-id-backup.service`:

```ini
[Unit]
Description=Back up the Cube ID name registry

[Service]
Type=oneshot
ExecStart=/opt/cubechat-id/deploy/backup-names.sh
```

`id/deploy/cubechat-id-backup.timer`:

```ini
[Unit]
Description=Daily Cube ID backup

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: Caddy block and README**

Append to `push/deploy/Caddyfile` (keep every existing block exactly as is):

```
id.cubechat.tech {
	encode gzip
	reverse_proxy 127.0.0.1:8090
}
```

`id/deploy/README.md` — deployment steps, verbatim:

````markdown
# cubechat-id deployment

Runs beside `cubechat-push` on the droplet (Node 22, user `cubechat`).

```bash
rsync -a --delete --exclude node_modules --exclude '*.db*' id/ root@209.38.225.225:/opt/cubechat-id/
ssh root@209.38.225.225 'cd /opt/cubechat-id && npm ci --omit=dev && chown -R cubechat:cubechat /opt/cubechat-id'
```

`/opt/cubechat-id/.env` (mode 600, owner cubechat):

```
PORT=8090
DB_PATH=/opt/cubechat-id/names.db
BANNED_PATH=/opt/cubechat-push/banned.json
ADMIN_TOKEN=<openssl rand -hex 32>
```

```bash
cp /opt/cubechat-id/deploy/cubechat-id.service /opt/cubechat-id/deploy/cubechat-id-backup.* /etc/systemd/system/
chmod +x /opt/cubechat-id/deploy/backup-names.sh
apt-get install -y sqlite3
systemctl daemon-reload && systemctl enable --now cubechat-id cubechat-id-backup.timer
```

Caddy: diff `/etc/caddy/Caddyfile` against `push/deploy/Caddyfile`, back the live one up to
`/root/Caddyfile.<date>`, copy the repo one, `caddy validate --config /etc/caddy/Caddyfile`, `systemctl reload caddy`.
Then check all three: `curl https://push.cubechat.tech/health`, `curl -I https://relay.cubechat.tech`,
`curl https://id.cubechat.tech/health`.

Revoke a name without a ban:

```bash
curl -s -X POST http://127.0.0.1:8090/admin/revoke -H "Authorization: Bearer $ADMIN_TOKEN" -d '{"name":"x","reason":"offensive"}'
```
````

- [ ] **Step 4: Deploy (after the owner's yes)**

Run the README commands in order. Confirm `id.cubechat.tech` resolves at a public resolver first: `curl -s "https://dns.google/resolve?name=id.cubechat.tech&type=A"` must show `209.38.225.225`.

- [ ] **Step 5: Verify live**

Run: `curl -s https://id.cubechat.tech/health` → `{"ok":true,"version":"2026-09-29-names","names":0}`; `curl -s https://push.cubechat.tech/health` and `curl -sI https://relay.cubechat.tech` unchanged; `curl -s "https://id.cubechat.tech/v1/available/admin"` → `{"available":false,"reason":"reserved"}`.

- [ ] **Step 6: Commit**

```bash
git add id/deploy push/deploy/Caddyfile
git commit -m "Run Cube ID at id.cubechat.tech behind the same Caddy, with a daily backup of the names"
```

---

### Task 6: Dart name rules

**Files:**
- Create: `lib/features/cube_id/domain/cube_name.dart`, `test/cube_id_name_test.dart`

**Interfaces:**
- Produces: `String normalizeCubeName(String raw)`; `enum CubeNameProblem { invalid, reserved }`; `CubeNameProblem? cubeNameProblem(String name)`; `const String cubeIdHost = 'id.cubechat.tech'`.

- [ ] **Step 1: Write the failing test (reads the server's fixture)**

`test/cube_id_name_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:cubechat/features/cube_id/domain/cube_name.dart';
import 'package:flutter_test/flutter_test.dart';

/// Same table as id/test/names.test.js, so the app never offers a name the
/// server refuses, or refuses one the server would take.
void main() {
  final cases = (jsonDecode(
    File('id/test/fixtures/name-cases.json').readAsStringSync(),
  ) as List<dynamic>)
      .cast<Map<String, dynamic>>();

  for (final c in cases) {
    test('name case ${c['input']}', () {
      final name = normalizeCubeName(c['input'] as String);
      expect(name, c['name']);
      expect(cubeNameProblem(name)?.name, c['problem']);
    });
  }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `flutter test test/cube_id_name_test.dart`
Expected: FAIL — `cube_name.dart` does not exist.

- [ ] **Step 3: Implement `lib/features/cube_id/domain/cube_name.dart`**

```dart
/// The rules a Cube ID @name has to pass. The server's twin is
/// `id/src/names.js`; both are pinned by `id/test/fixtures/name-cases.json`,
/// so the app never offers a name the server would refuse.
library;

const String cubeIdHost = 'id.cubechat.tech';

enum CubeNameProblem { invalid, reserved }

final RegExp _format = RegExp(r'^[a-z0-9_]{3,20}$');

const Set<String> _reserved = {
  'admin', 'administrator', 'root', 'support', 'help', 'helpdesk',
  'official', 'moderator', 'mod', 'staff', 'team', 'security', 'system',
  'null', 'undefined', 'cubechat', 'cube', 'cubeid', 'cube_id', 'apple',
  'google', 'brave1',
};

const List<String> _reservedParts = [
  'cubechat', 'admin', 'support', 'moderator',
];

// Latin transliterations of the filter's stems in
// lib/features/moderation/domain/profanity.dart; names have no spaces, so
// these match as substrings.
const List<String> _obscene = [
  'fuck', 'shit', 'cunt', 'bitch', 'whore', 'slut', 'nigg', 'fagg',
  'retard', 'dickhead', 'asshole', 'bastard',
  'huy', 'hui', 'xuy', 'xui', 'pizd', 'pezd', 'blya', 'suka', 'suki',
  'pidor', 'pidar', 'gandon', 'mudak', 'eblan', 'zalup', 'shluh', 'shlyuh',
  'kurva',
];

const List<String> _innocent = [
  'shiitake', 'scunthorpe', 'sukanya', 'bass', 'hui_ling', 'niggle',
];

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
```

- [ ] **Step 4: Run the test**

Run: `flutter test test/cube_id_name_test.dart`
Expected: PASS, 19 tests.

- [ ] **Step 5: Commit**

```bash
git add lib/features/cube_id/domain/cube_name.dart test/cube_id_name_test.dart
git commit -m "Hold the app's @name rules to the same table the server is held to"
```

---

### Task 7: Signed Cube ID events with proof-of-work, and the HTTP client

**Files:**
- Create: `lib/features/cube_id/data/cube_id_events.dart`, `lib/features/cube_id/data/cube_id_client.dart`, `test/cube_id_events_test.dart`, `test/cube_id_client_test.dart`

**Interfaces:**
- Consumes: `NostrEvent` (`lib/core/transport/nostr/nostr_event.dart`: fields `pubkey, createdAt, kind, tags, content`, `serializeForId()`, `copyWith`), `Secp256k1NostrSigner` (`deriveFromSeed(Uint8List)`, `npubHex`, `sign(NostrEvent)`), `DartSha256` from `package:cryptography/dart.dart`, `normalizeCubeName`.
- Produces:
  - `const int cubeIdKind = 24243; const int cubeIdPowBits = 16;`
  - `int leadingZeroBits(List<int> digest)`
  - `NostrEvent mineNonce(NostrEvent unsigned, int bits)` — pure, sync; returns a copy with `['nonce', n, '$bits']` whose id has ≥ `bits` leading zero bits (run it via `Isolate.run`).
  - `Future<NostrEvent> buildCubeIdEvent({required Secp256k1NostrSigner signer, required Map<String, Object?> content, required DateTime now, bool proofOfWork = false})`
  - `sealed class CubeIdResult` with `CubeIdOk(String? name)`, `CubeIdRefused(String code)` (server `error` string), `CubeIdOffline()`.
  - `class CubeIdClient { CubeIdClient({CubeIdHttp? http, String base = 'https://id.cubechat.tech'}); Future<CubeIdResult> send(NostrEvent e); Future<({bool available, String? reason})?> available(String name); Future<Uint8List?> card(String name); }` — `card` returns raw announcement bytes or null (404 / offline / bad base64).
  - `typedef CubeIdHttp = Future<({int status, String body})> Function(String method, Uri uri, {String? body});` (status `-1` = no answer, same contract as `ReportPoster`).

- [ ] **Step 1: Write the failing tests**

`test/cube_id_events_test.dart`:

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:cubechat/core/transport/nostr/nostr_event.dart';
import 'package:cubechat/core/transport/nostr/nostr_signer.dart';
import 'package:cubechat/features/cube_id/data/cube_id_events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('leadingZeroBits counts bits, not bytes', () {
    expect(leadingZeroBits([0x00, 0x00, 0xff]), 16);
    expect(leadingZeroBits([0x00, 0x0f]), 12);
    expect(leadingZeroBits([0x80]), 0);
  });

  test('mined events meet the difficulty and carry the NIP-13 tag', () {
    final unsigned = NostrEvent(
      pubkey: 'ab' * 32, createdAt: 1790000000, kind: cubeIdKind,
      tags: const [], content: '{"op":"claim"}',
    );
    final mined = mineNonce(unsigned, 12);
    final digest = const DartSha256()
        .hashSync(utf8.encode(mined.serializeForId())).bytes;
    expect(leadingZeroBits(digest), greaterThanOrEqualTo(12));
    expect(mined.tags.single.first, 'nonce');
    expect(mined.tags.single.last, '12');
  });

  test('a built claim is signed by the identity and verifies its id', () async {
    final signer = await Secp256k1NostrSigner.deriveFromSeed(
      Uint8List.fromList(List<int>.filled(32, 7)),
    );
    final e = await buildCubeIdEvent(
      signer: signer,
      content: {'op': 'renew'},
      now: DateTime.fromMillisecondsSinceEpoch(1790000000000),
    );
    expect(e.pubkey, signer.npubHex);
    expect(e.kind, cubeIdKind);
    expect(await e.hasValidId(), isTrue);
    expect(e.sig, isNotNull);
  });
}
```

`test/cube_id_client_test.dart`:

```dart
import 'dart:convert';

import 'package:cubechat/core/transport/nostr/nostr_event.dart';
import 'package:cubechat/features/cube_id/data/cube_id_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CubeIdClient client(int status, String response) => CubeIdClient(
        http: (method, uri, {body}) async => (status: status, body: response),
      );

  test('card decodes base64url and 404 is null', () async {
    final bytes = List<int>.generate(10, (i) => i);
    final ok = CubeIdClient(http: (m, u, {body}) async => (
          status: 200,
          body: jsonEncode({'card': base64Url.encode(bytes).replaceAll('=', '')}),
        ));
    expect(await ok.card('@Dima'), bytes);
    expect(await client(404, '{"error":"not-found"}').card('x'), isNull);
    expect(await client(-1, '').card('x'), isNull);
  });

  test('send maps statuses to results', () async {
    final e = NostrEvent(pubkey: 'a', createdAt: 0, kind: 24243, tags: const [], content: '{}');
    expect(await client(200, '{"name":"dima"}').send(e), isA<CubeIdOk>());
    final refused = await client(409, '{"error":"taken"}').send(e);
    expect((refused as CubeIdRefused).code, 'taken');
    expect(await client(-1, '').send(e), isA<CubeIdOffline>());
    expect(await client(503, '').send(e), isA<CubeIdOffline>());
  });

  test('available normalises the name in the URL', () async {
    Uri? seen;
    final c = CubeIdClient(http: (m, u, {body}) async {
      seen = u;
      return (status: 200, body: '{"available":true}');
    });
    expect((await c.available('@Dima'))!.available, isTrue);
    expect(seen!.path, '/v1/available/dima');
  });
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `flutter test test/cube_id_events_test.dart test/cube_id_client_test.dart`
Expected: FAIL — files do not exist.

- [ ] **Step 3: Implement `lib/features/cube_id/data/cube_id_events.dart`**

```dart
import 'dart:convert';
import 'dart:isolate';

import 'package:cryptography/dart.dart';

import '../../../core/transport/nostr/nostr_event.dart';
import '../../../core/transport/nostr/nostr_signer.dart';

/// Kind of every Cube ID operation. Its own kind, not push's 24242, so a
/// registration can never be replayed as a Cube ID change or the other way.
const int cubeIdKind = 24243;

/// NIP-13 difficulty the server demands on claim and rename. Around a second
/// on a phone; makes minting thousands of names expensive.
const int cubeIdPowBits = 16;

int leadingZeroBits(List<int> digest) {
  var bits = 0;
  for (final byte in digest) {
    if (byte == 0) {
      bits += 8;
      continue;
    }
    var b = byte;
    while (b & 0x80 == 0) {
      bits++;
      b <<= 1;
    }
    break;
  }
  return bits;
}

/// Pure and synchronous so it can run in [Isolate.run]; hashing with the
/// async [Sha256] would cost an await per attempt.
NostrEvent mineNonce(NostrEvent unsigned, int bits) {
  const sha = DartSha256();
  for (var nonce = 0;; nonce++) {
    final candidate = unsigned.copyWith(tags: [
      ['nonce', '$nonce', '$bits'],
    ]);
    final digest = sha.hashSync(utf8.encode(candidate.serializeForId())).bytes;
    if (leadingZeroBits(digest) >= bits) return candidate;
  }
}

Future<NostrEvent> buildCubeIdEvent({
  required Secp256k1NostrSigner signer,
  required Map<String, Object?> content,
  required DateTime now,
  bool proofOfWork = false,
}) async {
  var event = NostrEvent(
    pubkey: signer.npubHex,
    createdAt: now.millisecondsSinceEpoch ~/ 1000,
    kind: cubeIdKind,
    tags: const <List<String>>[],
    content: jsonEncode(content),
  );
  if (proofOfWork) {
    final unsigned = event;
    event = await Isolate.run(() => mineNonce(unsigned, cubeIdPowBits));
  }
  return signer.sign(event);
}
```

`Secp256k1NostrSigner.sign` computes the id itself (`_signHere` calls `event.withId()`), so the mined tags are hashed into the id it signs; do not call `withId()` separately.

- [ ] **Step 4: Implement `lib/features/cube_id/data/cube_id_client.dart`**

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/transport/nostr/nostr_event.dart';
import '../../../core/util/debug_log.dart';
import '../domain/cube_name.dart';

typedef CubeIdHttp = Future<({int status, String body})> Function(
  String method,
  Uri uri, {
  String? body,
});

sealed class CubeIdResult {
  const CubeIdResult();
}

class CubeIdOk extends CubeIdResult {
  const CubeIdOk(this.name);
  final String? name;
}

class CubeIdRefused extends CubeIdResult {
  const CubeIdRefused(this.code);

  /// The server's `error`: taken, reserved, invalid, has-name, pow, stale,
  /// card-mismatch, card-invalid, rate, no-name, bad-signature, bad-request.
  final String code;
}

class CubeIdOffline extends CubeIdResult {
  const CubeIdOffline();
}

Future<({int status, String body})> _defaultHttp(
  String method,
  Uri uri, {
  String? body,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.openUrl(method, uri);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(body);
    }
    final response = await request.close().timeout(const Duration(seconds: 15));
    final text = await response.transform(utf8.decoder).join();
    return (status: response.statusCode, body: text);
  } catch (e) {
    DebugLog.instance.log('CUBEID', '${uri.host} did not answer: $e');
    return (status: -1, body: '');
  } finally {
    client.close(force: true);
  }
}

class CubeIdClient {
  CubeIdClient({CubeIdHttp? http, String base = 'https://$cubeIdHost'})
      : _http = http ?? _defaultHttp,
        _base = Uri.parse(base);

  final CubeIdHttp _http;
  final Uri _base;

  Uri _at(String path) => _base.replace(path: path);

  Future<CubeIdResult> send(NostrEvent event) async {
    final r = await _http('POST', _at('/v1/op'), body: jsonEncode(event.toJson()));
    if (r.status == 200) {
      final name = _json(r.body)['name'];
      return CubeIdOk(name is String ? name : null);
    }
    if (r.status == -1 || r.status >= 500) return const CubeIdOffline();
    final code = _json(r.body)['error'];
    return CubeIdRefused(code is String ? code : 'http-${r.status}');
  }

  Future<({bool available, String? reason})?> available(String raw) async {
    final name = normalizeCubeName(raw);
    final r = await _http('GET', _at('/v1/available/${Uri.encodeComponent(name)}'));
    if (r.status != 200) return null;
    final json = _json(r.body);
    return (
      available: json['available'] == true,
      reason: json['reason'] as String?,
    );
  }

  Future<Uint8List?> card(String raw) async {
    final name = normalizeCubeName(raw);
    final r = await _http('GET', _at('/v1/card/${Uri.encodeComponent(name)}'));
    if (r.status != 200) return null;
    final card = _json(r.body)['card'];
    if (card is! String) return null;
    try {
      return base64Url.decode(base64Url.normalize(card));
    } on FormatException {
      return null;
    }
  }

  static Map<String, dynamic> _json(String body) {
    try {
      final v = jsonDecode(body);
      return v is Map<String, dynamic> ? v : const {};
    } on FormatException {
      return const {};
    }
  }
}
```

- [ ] **Step 5: Run the tests**

Run: `flutter test test/cube_id_events_test.dart test/cube_id_client_test.dart`
Expected: PASS.

- [ ] **Step 6: Measure proof-of-work on this machine and note it**

Run: `flutter test test/cube_id_events_test.dart --plain-name "mined"` with `cubeIdPowBits` temporarily used instead of 12 in a scratch run (do not commit that change). If 16 bits takes > 3 s on the desktop, it will be slower on a phone: lower `POW_BITS`/`cubeIdPowBits` to 14 on **both** sides (`id/src/events.js`, `cube_id_events.dart`, `id/test/helpers.js` default) and write the measured time into the comment above the constant.

- [ ] **Step 7: Commit**

```bash
git add lib/features/cube_id/data/cube_id_events.dart lib/features/cube_id/data/cube_id_client.dart test/cube_id_events_test.dart test/cube_id_client_test.dart
git commit -m "Sign Cube ID changes with the phone's own Nostr key, and pay a second of work to take a name"
```

---

### Task 8: `CubeIdController` — own name, lookup, maintenance, wipe

**Files:**
- Create: `lib/features/cube_id/data/cube_id_controller.dart`, `lib/features/cube_id/data/known_names_controller.dart`, `test/cube_id_controller_test.dart`
- Modify: `lib/core/identity/wipe_service.dart` (release before step 1; clear both controllers), `lib/app.dart` (call `maintain()` on start and on resume — find where `ReportClient.flush()` / push registration is triggered on start/resume and add the call beside it)

**Interfaces:**
- Consumes: `CubeIdClient`, `buildCubeIdEvent`, `normalizeCubeName`, `identityProvider` (`IdentityKeys.signPrivateKey`), `Secp256k1NostrSigner.deriveFromSeed`, `messagingServiceProvider` (`buildSignedAnnouncement(): Future<Uint8List>`, `addContactFromCard(String): Future<String>`), `ContactCard.encode(Uint8List)`, `PeerAnnouncement.verifyAndDecode`, `privacySettingsProvider` (`strangerReach` from Task 9 — until Task 9 lands, send `'all'`).
- Produces:
  - `class CubeIdState { final String? name; final DateTime? renewedAt; final String? cardDigest; }` persisted under settings key `cubeId.state` as a map.
  - `final cubeIdClientProvider = Provider<CubeIdClient>((_) => CubeIdClient());`
  - `class CubeIdController extends Notifier<CubeIdState>` with `Future<void> get loaded`, `Future<CubeIdResult> claim(String raw)`, `Future<CubeIdResult> rename(String raw)`, `Future<CubeIdResult> release({Duration timeout = const Duration(seconds: 3)})`, `Future<void> maintain()`, `Future<void> pushReach(String reach)`, `Future<void> clear()`; provider `cubeIdControllerProvider`.
  - `sealed class LookupResult` → `LookupFound(String pubkeyHex, String name)`, `LookupNotFound()`, `LookupOffline()`; `Future<LookupResult> lookupAndAdd(String raw)` on the controller.
  - `class KnownNamesController extends Notifier<Map<String, String>>` (`pubkeyHex → name`, settings key `cubeId.knownNames`) with `remember(String pubkeyHex, String name)`, `clear()`; provider `knownNamesProvider`.

- [ ] **Step 1: Write the failing test**

`test/cube_id_controller_test.dart` — build a `ProviderContainer` with Hive in a temp dir exactly as `test/backup_service_test.dart` does (mock `FlutterSecureStorage`, `_BackupPaths`, `settleBackgroundStorage` in tearDown), and override `cubeIdClientProvider` with a `CubeIdClient(http: fake)` that records calls. Cases:

```dart
test('claim stores the name and sends a proof-of-work claim with our card', () async {
  final sent = <Map<String, dynamic>>[];
  final c = containerWith(http: (m, u, {body}) async {
    if (body != null) sent.add(jsonDecode(body) as Map<String, dynamic>);
    return (status: 200, body: '{"name":"dima"}');
  });
  final ctl = c.read(cubeIdControllerProvider.notifier);
  await ctl.loaded;
  expect(await ctl.claim('@Dima'), isA<CubeIdOk>());
  expect(c.read(cubeIdControllerProvider).name, 'dima');
  final content = jsonDecode(sent.single['content'] as String) as Map<String, dynamic>;
  expect(content['op'], 'claim');
  expect(content['name'], 'dima');
  expect((sent.single['tags'] as List).single.first, 'nonce');
});

test('a refused claim keeps no name', () async {
  final c = containerWith(http: (m, u, {body}) async => (status: 409, body: '{"error":"taken"}'));
  final ctl = c.read(cubeIdControllerProvider.notifier);
  await ctl.loaded;
  expect((await ctl.claim('dima') as CubeIdRefused).code, 'taken');
  expect(c.read(cubeIdControllerProvider).name, isNull);
});

test('maintain renews after 7 days and updates when our card changed', () async {
  final ops = <String>[];
  final c = containerWith(http: (m, u, {body}) async {
    if (body != null) ops.add((jsonDecode(jsonDecode(body)['content'] as String) as Map)['op'] as String);
    return (status: 200, body: '{"name":"dima"}');
  });
  final ctl = c.read(cubeIdControllerProvider.notifier);
  await ctl.loaded;
  await ctl.claim('dima');
  ops.clear();
  await ctl.maintain(); // same card, renewed just now
  expect(ops, isEmpty);
  ctl.debugSetRenewedAt(DateTime.now().subtract(const Duration(days: 8)));
  await ctl.maintain();
  expect(ops, ['renew']);
  ctl.debugSetCardDigest('stale');
  ops.clear();
  await ctl.maintain();
  expect(ops, ['update']);
});

test('release does not wait longer than the timeout', () async {
  final c = containerWith(http: (m, u, {body}) async {
    await Future<void>.delayed(const Duration(seconds: 10));
    return (status: 200, body: '{}');
  });
  final ctl = c.read(cubeIdControllerProvider.notifier);
  await ctl.loaded;
  final clock = Stopwatch()..start();
  await ctl.release(timeout: const Duration(milliseconds: 200));
  expect(clock.elapsedMilliseconds, lessThan(1500));
});

test('lookup rejects a card with a broken signature', () async {
  final c = containerWith(http: (m, u, {body}) async => (
        status: 200,
        body: jsonEncode({'card': base64Url.encode(List<int>.filled(200, 1))}),
      ));
  final ctl = c.read(cubeIdControllerProvider.notifier);
  expect(await ctl.lookupAndAdd('@dima'), isA<LookupNotFound>());
});
```

`containerWith` overrides `cubeIdClientProvider` and, so the test needs no live `MessagingService`, overrides a small seam: add to the controller a `@visibleForTesting static Future<Uint8List> Function(Ref)? cardSourceOverride` used instead of `messagingServiceProvider.buildSignedAnnouncement()` when set; the test sets it to return a card signed in the test (mint with `PeerAnnouncement.sign` as in Task 2, with `nostrPubkey` = the signer derived from the test identity so the digest is stable).

- [ ] **Step 2: Run it to see it fail**

Run: `flutter test test/cube_id_controller_test.dart`
Expected: FAIL — controller missing.

- [ ] **Step 3: Implement `known_names_controller.dart`**

Mirror `ArchivedChatsController` (`lib/features/chats/data/archived_chats_controller.dart`) — same box, `_load` merges under current state, `_writePending` — storing a `Map<String, String>` under `cubeId.knownNames`:

```dart
class KnownNamesController extends Notifier<Map<String, String>> {
  static const _key = 'cubeId.knownNames';
  Box<dynamic>? _box;
  Future<void>? _loading;
  bool _writePending = false;

  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  Map<String, String> build() {
    unawaited(_loading = _load());
    return const <String, String>{};
  }

  Future<void> _load() async {
    try {
      final box = await hiveCipherProvider.openEncryptedBox<dynamic>(HiveBoxes.settings);
      _box = box;
      final raw = box.get(_key);
      if (raw is Map) {
        state = {
          for (final e in raw.entries)
            if (e.key is String && e.value is String) e.key as String: e.value as String,
          ...state,
        };
      }
    } catch (e) {
      debugPrint('KnownNamesController load failed: $e');
    }
    if (_writePending && _box != null) {
      _writePending = false;
      await _persist();
    }
  }

  Future<void> remember(String pubkeyHex, String name) async {
    if (state[pubkeyHex] == name) return;
    state = {...state, pubkeyHex: name};
    await _persist();
  }

  Future<void> clear() async {
    state = const {};
    await _persist();
  }

  Future<void> _persist() async {
    final box = _box;
    if (box == null) {
      _writePending = true;
      return;
    }
    await box.put(_key, Map<String, String>.from(state));
  }
}

final knownNamesProvider =
    NotifierProvider<KnownNamesController, Map<String, String>>(KnownNamesController.new);
```

- [ ] **Step 4: Implement `cube_id_controller.dart`**

Key behaviours (write them out in full in the file):

```dart
class CubeIdState {
  const CubeIdState({this.name, this.renewedAt, this.cardDigest});
  final String? name;
  final DateTime? renewedAt;
  /// Hex SHA-256 of the card last sent to the server. A different digest for
  /// the card we would send now means the nickname, avatar or prekey changed.
  final String? cardDigest;
  static const empty = CubeIdState();
  Map<String, Object?> toMap() => {
        'name': name,
        'renewedAt': renewedAt?.millisecondsSinceEpoch,
        'cardDigest': cardDigest,
      };
  static CubeIdState fromMap(Map<dynamic, dynamic> m) => CubeIdState(
        name: m['name'] as String?,
        renewedAt: m['renewedAt'] is int
            ? DateTime.fromMillisecondsSinceEpoch(m['renewedAt'] as int)
            : null,
        cardDigest: m['cardDigest'] as String?,
      );
}
```

Controller methods:

- `_signer()` → `Secp256k1NostrSigner.deriveFromSeed(Uint8List.fromList((await ref.read(identityProvider.future)).signPrivateKey))` (same derivation as `ReportClient._attempt`).
- `_card()` → `cardSourceOverride?.call(ref) ?? ref.read(messagingServiceProvider).buildSignedAnnouncement()`; `_digest(bytes)` → hex of `const DartSha256().hashSync(bytes).bytes`.
- `claim(raw)`: `name = normalizeCubeName(raw)`; if `cubeNameProblem(name) != null` return `CubeIdRefused(problem.name)` without network; build with `proofOfWork: true`, content `{'op': state.name == null ? 'claim' : 'rename', 'name': name, 'card': base64Url.encode(card).replaceAll('=', '')}`; on `CubeIdOk` set state `(name, now, digest)` and persist; return the result. `rename(raw)` is `claim(raw)` when a name exists.
- `release({timeout})`: if no name, return `CubeIdOk(null)`; send `{'op':'release'}` with `.timeout(timeout, onTimeout: () => const CubeIdOffline())`; **always** clear local state afterwards (the user asked for it gone; an unreachable server frees it after 182 days).
- `maintain()`: if no name return; `card = await _card()`; if `_digest(card) != state.cardDigest` → send `{'op':'update','card':…,'reach': ref.read(privacySettingsProvider).strangerReach.wire}` (before Task 9 exists use `'all'`) and on OK store the new digest and `renewedAt = now`; else if `renewedAt` is null or older than 7 days → send `{'op':'renew'}` and on OK store `renewedAt = now`. On `CubeIdRefused('no-name')` (expired or revoked on the server) clear local state. Never throw; log to `DebugLog` tag `CUBEID`.
- `pushReach(String reach)`: if a name exists, send `update` with the current card and `reach`.
- `lookupAndAdd(raw)`: `name = normalizeCubeName(raw)`; if `cubeNameProblem(name) == CubeNameProblem.invalid` → `LookupNotFound()`; `bytes = await client.card(name)`; `null` → distinguish offline by also checking `client.available(name) == null` → `LookupOffline()`, else `LookupNotFound()`; then `try { await PeerAnnouncement.verifyAndDecode(bytes); } on FormatException { return LookupNotFound(); }`; `pubkeyHex = await ref.read(messagingServiceProvider).addContactFromCard(ContactCard.encode(bytes))` (catch `StateError` for our own card → `LookupNotFound()`); `await ref.read(knownNamesProvider.notifier).remember(pubkeyHex, name)`; return `LookupFound(pubkeyHex, name)`.
- `@visibleForTesting void debugSetRenewedAt(DateTime t)` and `debugSetCardDigest(String d)`.
- `clear()`: state empty, delete `cubeId.state`.

- [ ] **Step 5: Wire maintenance and wipe**

In `lib/core/identity/wipe_service.dart` at the very top of `emergencyWipe` (before `MediaPaths.forgetAll()`):

```dart
  // Give the name back before the key that owns it is gone. Bounded: a wipe
  // is an emergency and does not wait on a server — an unreachable one frees
  // the name after six months on its own.
  await ref.read(cubeIdControllerProvider.notifier).release();
```

and with the other clears: `await ref.read(knownNamesProvider.notifier).clear();`.

In `lib/app.dart`, `_CubechatAppState._refreshModeration()` (~line 107) already runs on start and on resume; add `unawaited(ref.read(cubeIdControllerProvider.notifier).maintain());` there, with a one-line comment that it renews weekly and re-sends the card when it changed.

- [ ] **Step 6: Run the tests**

Run: `flutter test test/cube_id_controller_test.dart test/emergency_wipe_test.dart` (the second only if it exists — `ls test | grep -i wipe`; run whichever wipe tests exist).
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/features/cube_id/data/cube_id_controller.dart lib/features/cube_id/data/known_names_controller.dart test/cube_id_controller_test.dart lib/core/identity/wipe_service.dart lib/app.dart
git commit -m "Keep your @name alive and current in the background, and give it back on emergency wipe"
```

---

### Task 9: "Who can message me from the internet" and message requests

**Files:**
- Modify: `lib/features/profile/data/privacy_settings_controller.dart`
- Create: `lib/features/chats/data/message_requests_controller.dart`, `lib/features/chats/domain/stranger_gate.dart`, `test/stranger_gate_test.dart`, `test/message_requests_controller_test.dart`
- Modify (additive): `lib/core/transport/messaging_service.dart` (inbound gate right after the blocked-peer drop at ~line 7318), `lib/features/chat/data/conversation_settings_controller.dart` (`sharesReadReceiptsWith`, `acceptsCallsFrom`), `lib/core/identity/wipe_service.dart`

**Interfaces:**
- Produces:
  - `enum StrangerReach { all, request, none }` with `String get wire => name;` and `static StrangerReach fromWire(String? s)` (default `all`); `PrivacySettings.strangerReach` (default `StrangerReach.all`), `PrivacySettingsController.setStrangerReach(StrangerReach)` persisted under `privacy.strangerReach` as the wire string; also calls `cubeIdControllerProvider.notifier.pushReach(value.wire)`.
  - `class MessageRequests { final Set<String> pending; final Set<String> accepted; }`; `MessageRequestsController extends Notifier<MessageRequests>` with `loaded`, `markPending(String peer)`, `accept(String peer)` (moves to accepted), `drop(String peer)` (removes from both), `clearPending()` (when reach goes back to `all`), `clear()`; provider `messageRequestsProvider`; settings keys `requests.pending`, `requests.accepted`.
  - `enum StrangerVerdict { deliver, request, drop }` and the pure function:
    ```dart
    StrangerVerdict strangerVerdict({
      required StrangerReach reach,
      required bool viaInternet,
      required bool wroteToThem,
      required bool accepted,
      required bool alreadyPending,
    })
    ```
- Consumes: `hasWrittenIn(Iterable<Message>?)` from `lib/features/moderation/domain/profanity.dart`, `messagesControllerProvider.notifier.loaded`.

- [ ] **Step 1: Write the failing pure-function test**

`test/stranger_gate_test.dart`:

```dart
import 'package:cubechat/features/chats/domain/stranger_gate.dart';
import 'package:cubechat/features/profile/data/privacy_settings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  StrangerVerdict v(StrangerReach reach,
          {bool internet = true, bool wrote = false, bool accepted = false, bool pending = false}) =>
      strangerVerdict(
        reach: reach, viaInternet: internet, wroteToThem: wrote,
        accepted: accepted, alreadyPending: pending,
      );

  test('everyone: always delivered', () {
    expect(v(StrangerReach.all), StrangerVerdict.deliver);
  });
  test('bluetooth neighbours are never gated', () {
    expect(v(StrangerReach.none, internet: false), StrangerVerdict.deliver);
    expect(v(StrangerReach.request, internet: false), StrangerVerdict.deliver);
  });
  test('people I wrote to, or accepted, are contacts', () {
    expect(v(StrangerReach.none, wrote: true), StrangerVerdict.deliver);
    expect(v(StrangerReach.request, accepted: true), StrangerVerdict.deliver);
  });
  test('request folds strangers; nobody drops them', () {
    expect(v(StrangerReach.request), StrangerVerdict.request);
    expect(v(StrangerReach.request, pending: true), StrangerVerdict.request);
    expect(v(StrangerReach.none), StrangerVerdict.drop);
  });
  test('a pending request stays a request even under nobody', () {
    expect(v(StrangerReach.none, pending: true), StrangerVerdict.request);
  });
}
```

- [ ] **Step 2: Run to see it fail**

Run: `flutter test test/stranger_gate_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement the setting and the gate**

`lib/features/chats/domain/stranger_gate.dart`:

```dart
import '../../profile/data/privacy_settings_controller.dart';

/// What to do with a message from somebody who is not a contact.
///
/// Only internet arrivals are gated: a phone cannot tell a stranger who found
/// our @name from one who got our QR card — both arrive over Nostr from an
/// unknown key — while a Bluetooth neighbour is, by definition, standing
/// here. A "contact" is someone we have written to, or whose request we
/// accepted. A request already waiting stays a request whatever the setting
/// says now, so switching to "nobody" never silently deletes it.
enum StrangerVerdict { deliver, request, drop }

StrangerVerdict strangerVerdict({
  required StrangerReach reach,
  required bool viaInternet,
  required bool wroteToThem,
  required bool accepted,
  required bool alreadyPending,
}) {
  if (!viaInternet || wroteToThem || accepted) return StrangerVerdict.deliver;
  if (alreadyPending) return StrangerVerdict.request;
  return switch (reach) {
    StrangerReach.all => StrangerVerdict.deliver,
    StrangerReach.request => StrangerVerdict.request,
    StrangerReach.none => StrangerVerdict.drop,
  };
}
```

In `privacy_settings_controller.dart`: add `enum StrangerReach` (as specified), the `strangerReach` field with default `StrangerReach.all` in the constructor, `initial`, `copyWith`, `==`, `hashCode`; `_keyStrangerReach = 'privacy.strangerReach'`; load with `StrangerReach.fromWire(box.get(_keyStrangerReach) as String?)`; change `_put(String key, bool value)` to `_put(String key, Object value)`; add

```dart
  Future<void> setStrangerReach(StrangerReach value) async {
    state = state.copyWith(strangerReach: value);
    await _put(_keyStrangerReach, value.wire);
    if (value == StrangerReach.all) {
      await ref.read(messageRequestsProvider.notifier).clearPending();
    }
    // The registry hides the name for "nobody"; tell it. No-op without a name.
    unawaited(ref.read(cubeIdControllerProvider.notifier).pushReach(value.wire));
  }
```

and delete the key in `reset()`. Then in `CubeIdController.maintain()` (Task 8) replace the temporary `'all'` with `ref.read(privacySettingsProvider).strangerReach.wire`, so the registry learns the current setting with every `update`.

`message_requests_controller.dart`: mirror `ArchivedChatsController` for two sets (`requests.pending`, `requests.accepted`), with the methods listed above.

- [ ] **Step 4: Controller test**

`test/message_requests_controller_test.dart` (Hive harness as in Task 8): `markPending('a')` → pending `{a}`; `accept('a')` → pending `{}`, accepted `{a}`; `drop('a')` → both empty; a new container after `markPending('b')` loads `{b}` from disk; `clearPending()` empties pending only.

- [ ] **Step 5: The inbound gate (load `wire-protocol` first; additive only)**

In `messaging_service.dart`, immediately after the `drop inbound from blocked peer` block (~line 7318–7331), add:

```dart
      // Who may reach us from the internet as a stranger — Profile →
      // Privacy. Decided here, once, on arrival, and remembered: the chat list
      // cannot work it out later from history that may not be loaded yet.
      if (senderPub != null && incomingRoute == MessageRoute.internet) {
        final sender = _hexOf(senderPub);
        final requests = _ref.read(messageRequestsProvider);
        await _ref.read(messagesControllerProvider.notifier).loaded;
        final verdict = strangerVerdict(
          reach: _ref.read(privacySettingsProvider).strangerReach,
          viaInternet: true,
          wroteToThem: hasWrittenIn(_ref.read(messagesControllerProvider)[sender]),
          accepted: requests.accepted.contains(sender),
          alreadyPending: requests.pending.contains(sender),
        );
        if (verdict == StrangerVerdict.drop) {
          DebugLog.instance.log('MESH', 'drop stranger over internet: reach is none');
          return;
        }
        if (verdict == StrangerVerdict.request &&
            unpacked.type.isConversational) {
          unawaited(_ref.read(messageRequestsProvider.notifier).markPending(sender));
        }
      }
```

`isConversational`: only message-bearing types open a request — text, textReply, media manifests, image/audio/file chunks, `callSignal` invites; receipts, typing, presence, reactions and announcements must not. If `InnerPayloadType` has no such getter, add one in `lib/core/transport/inner_payload.dart` as an extension (`extension on InnerPayloadType { bool get isConversational => switch (this) { … }; }`) listing the existing values explicitly, with a comment that new types default to `false`. This is a local predicate, not a wire change.

In `conversation_settings_controller.dart`:

```dart
  bool sharesReadReceiptsWith(String chatId) =>
      ref.read(privacySettingsProvider).shareReadReceipts &&
      !forChat(chatId).hideReadReceipts &&
      // A stranger's request learns nothing — not even that it was read —
      // until it is accepted.
      !ref.read(messageRequestsProvider).pending.contains(chatId);
```

and in `acceptsCallsFrom(chatId)` return `false` first when `ref.read(messageRequestsProvider).pending.contains(chatId)` (the call controller already answers a refused call as busy).

In `wipe_service.dart`: `await ref.read(messageRequestsProvider.notifier).clear();`.

- [ ] **Step 6: Inbound test**

Add to `test/message_requests_controller_test.dart` (or a new `test/stranger_inbound_test.dart` following the harness of the nearest existing messaging-service inbound test — `grep -ln "incomingRoute\|MessageRoute.internet" test` to find one): with reach `request`, an internet text from an unknown sender marks it pending and is stored; with reach `none` it is not stored; the same sender after I wrote to them is delivered and not marked; a read-receipt frame from a stranger does not mark pending. Also: `sharesReadReceiptsWith(pendingPeer)` is false; `acceptsCallsFrom(pendingPeer)` is false.

- [ ] **Step 7: Run everything touched**

Run: `flutter test test/stranger_gate_test.dart test/message_requests_controller_test.dart` plus the inbound test file, then `flutter test` (full suite, excluding goldens: `flutter test --exclude-tags golden`).
Expected: PASS; no previously green test turns red.

- [ ] **Step 8: Commit**

```bash
git add lib/features/chats/domain/stranger_gate.dart lib/features/chats/data/message_requests_controller.dart lib/features/profile/data/privacy_settings_controller.dart lib/core/transport/messaging_service.dart lib/core/transport/inner_payload.dart lib/features/chat/data/conversation_settings_controller.dart lib/core/identity/wipe_service.dart test/stranger_gate_test.dart test/message_requests_controller_test.dart
git commit -m "Let people choose who reaches them from the internet as a stranger: everyone, by request, or nobody"
```

(Add the inbound test file to `git add` by its actual name.)

---

### Task 10: Requests drawer and the request banner

**Files:**
- Create: `lib/features/chats/presentation/requests_screen.dart`, `test/requests_screen_test.dart`
- Modify: `lib/features/chats/presentation/chats_list_screen.dart` (`visibleChatsProvider`, new `requestChatsProvider`, `_RequestsEntry` above `_ArchiveEntry`), `lib/core/routing/app_router.dart` (`/requests`), the chat screen (banner) — `lib/features/chat/presentation/chat_screen.dart`, `lib/l10n/app_en.arb`, `lib/l10n/app_uk.arb`

**Interfaces:**
- Consumes: `messageRequestsProvider` (Task 9), `chatsProvider`, `compareChatRows`, `knownPeersControllerProvider.notifier.setBlocked`, `messagesControllerProvider.notifier.clearForChat(String)`.
- Produces: `final requestChatsProvider = Provider<List<Chat>>` (chats whose id is in `pending`, sorted with `compareChatRows`); `visibleChatsProvider` excludes pending ids; `RequestsScreen`; widget `RequestBanner(chatId)` used by the chat screen.

l10n keys (add to both files; `uk` values in parentheses):
`requestsTitle` "Requests" ("Запити"); `requestsEmpty` "No requests" ("Запитів немає"); `requestBanner` "{name} is not in your contacts. They can't see that you've read this or call you until you accept." ("{name} немає у ваших контактах. Поки ви не приймете запит, людина не бачить, що ви прочитали, і не може вам подзвонити."); `requestAccept` "Accept" ("Прийняти"); `requestDelete` "Delete" ("Видалити"); `requestBlock` "Block" ("Заблокувати"). `requestBanner` takes `{name}` with `"placeholders": {"name": {"type": "String"}}`.

- [ ] **Step 1: Write the failing widget test**

`test/requests_screen_test.dart`: pump `RequestsScreen` under a `ProviderScope` overriding `requestChatsProvider` with one `Chat` and `messageRequestsProvider` with a fake controller; expect the chat row and three actions; tap "Accept" → fake records `accept(id)`; with an empty list expect `requestsEmpty` text. Use the harness style of the nearest chats-list widget test (`ls test | grep -i "archive\|chats_list"`).

- [ ] **Step 2: Run to see it fail**

Run: `flutter test test/requests_screen_test.dart` → FAIL.

- [ ] **Step 3: Implement**

- In `chats_list_screen.dart`, change `visibleChatsProvider` to also skip `ref.watch(messageRequestsProvider).pending`, and add `requestChatsProvider` next to `archivedChatsProvider` (same shape). Add `_RequestsEntry` modelled on `_ArchiveEntry` (lines ~1373–1400): hidden when the list is empty; shows `t.requestsTitle` and the count; `onTap: () => context.push('/requests')`. Place it directly above `_ArchiveEntry` where that is inserted.
- `requests_screen.dart`: a `ConsumerWidget` using the archive screen's layout (`lib/features/chats/presentation/archive_screen.dart`) — list of rows; each row opens the chat (`context.push('/chat/$id?name=…')`) and has three `TextButton`s: Accept → `accept(id)`; Delete → `messagesController.clearForChat(id)` then `drop(id)`; Block → `knownPeers.setBlocked(id, true)` then `drop(id)`.
- `RequestBanner` (same file, exported): shown at the top of the chat screen when `pending.contains(chatId)` — glass card with `t.requestBanner(name)` and the same three buttons; Delete/Block also `context.pop()`.
- Router: `GoRoute(path: '/requests', parentNavigatorKey: _rootNavKey, pageBuilder: (context, state) => fadeSlidePage(child: const AuroraBackground(child: RequestsScreen()), state: state))` next to `/archive`.
- Sending a message in a pending chat accepts it: in the chat screen's send path, if `pending.contains(chatId)` call `accept(chatId)` first (replying is accepting).

- [ ] **Step 4: gen-l10n, run tests and analyze**

Run: `flutter gen-l10n && flutter test test/requests_screen_test.dart && flutter analyze`
Expected: PASS; analyze shows no errors or warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/features/chats/presentation/requests_screen.dart lib/features/chats/presentation/chats_list_screen.dart lib/core/routing/app_router.dart lib/features/chat/presentation/chat_screen.dart lib/l10n/app_en.arb lib/l10n/app_uk.arb lib/l10n/app_localizations*.dart test/requests_screen_test.dart
git commit -m "Fold strangers' first messages into a Requests drawer until they are accepted"
```

---

### Task 11: Cube ID screen, the privacy row, and lookup by @name

**Files:**
- Create: `lib/features/cube_id/presentation/cube_id_screen.dart`, `test/cube_id_screen_test.dart`
- Modify: `lib/features/profile/presentation/profile_screen.dart` (a Cube ID row; a three-way reach row after the calls switch at ~line 1436), `lib/features/peers/presentation/contact_card_screen.dart` (`_AddContactField._submit` accepts `@name`; own `@name` shown above the card), `lib/features/peers/presentation/contact_profile_screen.dart` (show `@name` from `knownNamesProvider` under the nickname), `lib/core/routing/app_router.dart` (`/cube-id`), `lib/l10n/app_en.arb`, `lib/l10n/app_uk.arb`

**Interfaces:**
- Consumes: `cubeIdControllerProvider` (`claim`, `rename`, `release`, `lookupAndAdd`), `cubeIdClientProvider.available`, `cubeNameProblem`, `knownNamesProvider`, `privacySettingsProvider`/`setStrangerReach`, `showGlassToast(context, message, tone:, icon:)`, `confirmAction` (as used in `backup_screen.dart`), `share_plus` (already a dependency).

l10n keys (en / uk):
`cubeIdTitle` "Cube ID" / "Cube ID"; `cubeIdRowEmpty` "Take a short @name" / "Займіть коротке @ім’я"; `cubeIdExplainer` "Your @name points to your contact card. The server keeps only the name and your public card — never your messages." / "Ваше @ім’я вказує на вашу картку контакту. Сервер зберігає лише ім’я та публічну картку — ніколи не повідомлення."; `cubeIdFieldHint` "a–z, 0–9 and _, 3–20 characters" / "a–z, 0–9 та _, 3–20 символів"; `cubeIdAvailable` "Available" / "Вільне"; `cubeIdTaken` "Taken" / "Зайняте"; `cubeIdReserved` "Not allowed" / "Недоступне"; `cubeIdInvalid` "Only a–z, 0–9 and _, 3–20 characters" / "Лише a–z, 0–9 та _, 3–20 символів"; `cubeIdClaim` "Take this name" / "Зайняти"; `cubeIdWorking` "Securing the name…" / "Закріплюємо ім’я…"; `cubeIdChange` "Change" / "Змінити"; `cubeIdRelease` "Release" / "Звільнити"; `cubeIdReleaseConfirm` "Release @{name}? Anyone will be able to take it." / "Звільнити @{name}? Його зможе зайняти будь-хто."; `cubeIdShare` "Share" / "Поділитися"; `cubeIdShareText` "Find me in cubechat: @{name}\nhttps://cubechat.tech/u.html#{name}" / "Знайдіть мене в cubechat: @{name}\nhttps://cubechat.tech/u.html#{name}"; `cubeIdFailed` "Couldn't save the name. Try again." / "Не вдалося зберегти ім’я. Спробуйте ще раз."; `cubeIdOffline` "No internet" / "Немає інтернету"; `lookupNotFound` "No one with that @name" / "Нікого з таким @ім’ям"; `addContactHintName` "Paste a card or type @name" / "Вставте картку або введіть @ім’я"; `strangerReachTitle` "Who can message me from the internet" / "Хто може писати мені з інтернету"; `strangerReachAll` "Everyone" / "Усі"; `strangerReachRequest` "Request" / "Через запит"; `strangerReachNone` "Nobody" / "Ніхто"; `strangerReachHint` "For people you haven't written to who reach you over the internet. People nearby over Bluetooth are not affected." / "Для людей, яким ви не писали і які пишуть через інтернет. Людей поруч через Bluetooth це не стосується.". Placeholders `{name}` as String.

- [ ] **Step 1: Write the failing widget test**

`test/cube_id_screen_test.dart` with `cubeIdControllerProvider` and `cubeIdClientProvider` overridden by fakes:
- empty state: typing `ab` shows `cubeIdInvalid` without calling the client; typing `dima` and waiting 400 ms calls `available('dima')` once and shows `cubeIdAvailable`; tapping `cubeIdClaim` calls `claim('dima')`.
- `CubeIdRefused('taken')` from `claim` shows `cubeIdTaken`; `CubeIdOffline` shows `cubeIdOffline`.
- with a name: shows `@dima`, `cubeIdChange`, `cubeIdRelease`, `cubeIdShare`; Release asks for confirmation before calling `release()`.

- [ ] **Step 2: Run to see it fail** — `flutter test test/cube_id_screen_test.dart` → FAIL.

- [ ] **Step 3: Implement the screen**

`CubeIdScreen` (`ConsumerStatefulWidget`, `Scaffold` with transparent `AppBar` like `AboutScreen`, body `ListView` with 20 px padding):
- explainer text (`AppColors.textOnGlassDim`);
- if `state.name == null` or the user tapped Change: a `TextField` with prefix text `@`, hint `cubeIdFieldHint`, `onChanged` → normalise; local `cubeNameProblem` shows `cubeIdInvalid`/`cubeIdReserved` at once; otherwise a 400 ms `Timer` debounce then `available()`; status line shows available/taken/reserved; a `FilledButton` `cubeIdClaim` enabled only when available, which shows `cubeIdWorking` with a spinner while `claim`/`rename` runs (proof-of-work takes ~1 s);
- if a name exists: big `@name` (`AppTypography.heading(size: 23)`), and three `_AboutAction`-style rows (reuse the look from `about_screen.dart`): Change, Share (`Share.share(t.cubeIdShareText(name))`), Release (`confirmAction` then `release()` then toast).
Colours via `AppColors` only (glass-ui skill).

- [ ] **Step 4: Profile rows and routing**

- `/cube-id` route beside `/backup` in `app_router.dart`, wrapped in `AuroraBackground` like the others.
- In `profile_screen.dart`, a row opening `/cube-id` near the backup row (same `_frame(...)` pattern as the backup row at ~line 520–535): title `cubeIdTitle`, subtitle `@name` or `cubeIdRowEmpty`.
- After the calls switch (~line 1443), a reach row: title `strangerReachTitle`, hint `strangerReachHint`, and a `SegmentedButton<StrangerReach>` with the three labels, `selected: {s.strangerReach}`, `onSelectionChanged: (v) => n.setStrangerReach(v.first)`, styled with `AppColors.brandPrimary` for the selected segment.

- [ ] **Step 5: Lookup in the add-contact field**

In `contact_card_screen.dart` `_AddContactFieldState._submit`, before `addContactFromCard(raw)`:

```dart
    final asName = normalizeCubeName(raw);
    if (!ContactCard.looksLikeCard(raw) && cubeNameProblem(asName) != CubeNameProblem.invalid) {
      final result = await ref.read(cubeIdControllerProvider.notifier).lookupAndAdd(asName);
      if (!mounted) return;
      switch (result) {
        case LookupFound(:final pubkeyHex):
          final name = ref.read(knownPeersControllerProvider)[pubkeyHex]?.displayName ?? '';
          _controller.clear();
          showGlassToast(context, t.contactAdded(name), tone: ToastTone.success);
          context.pushReplacement('/chat/$pubkeyHex?name=${Uri.encodeComponent(name)}');
        case LookupNotFound():
          showGlassToast(context, t.lookupNotFound, tone: ToastTone.danger);
        case LookupOffline():
          showGlassToast(context, t.cubeIdOffline, tone: ToastTone.danger);
      }
      setState(() => _busy = false);
      return;
    }
```

(keep the existing `_busy` handling consistent with the method's current `try/finally`), change the field's hint to `t.addContactHintName`, and above the own-card preview show `@name` from `cubeIdControllerProvider` when set.

In `contact_profile_screen.dart`, under the nickname, show `'@${names[pubkeyHex]}'` from `knownNamesProvider` when present (dim text).

- [ ] **Step 6: gen-l10n, tests, analyze**

Run: `flutter gen-l10n && flutter test test/cube_id_screen_test.dart && flutter test --exclude-tags golden && flutter analyze`
Expected: all PASS; analyze without errors/warnings. If a golden of the profile or contact-card screen changes (`flutter test --tags golden`), re-record it only after looking at the before/after PNG (memory: render before claiming a visual fix).

- [ ] **Step 7: Commit**

```bash
git add lib/features/cube_id/presentation/cube_id_screen.dart lib/features/profile/presentation/profile_screen.dart lib/features/peers/presentation/contact_card_screen.dart lib/features/peers/presentation/contact_profile_screen.dart lib/core/routing/app_router.dart lib/l10n/app_en.arb lib/l10n/app_uk.arb lib/l10n/app_localizations*.dart test/cube_id_screen_test.dart
git commit -m "Take an @name in Profile and find people by typing theirs where you paste a card"
```

---

### Task 12: Legal documents and the share page

**Files:**
- Modify: `docs/legal/privacy-policy.uk.md`, `docs/legal/privacy-policy.en.md`, `docs/legal/store-disclosures.md`, `docs/legal/README.md` (if it indexes servers)
- Landing repo `D:/projects/landing`: create `public/u.html`; modify `public/privacy.html`

**Interfaces:**
- Produces: a published `https://cubechat.tech/u.html#<name>` and an updated `https://cubechat.tech/privacy.html`.

- [ ] **Step 1: Privacy policy (uk and en, same content)**

Add a section "Cube ID (короткі імена)" / "Cube ID (short names)" stating exactly: optional; stored at `id.cubechat.tech`: the name, the public contact card (public keys, nickname, avatar digest), the "who can message me" setting, times of creation and last renewal; the name is public and anyone who knows it can find the card, unless "Nobody" is chosen; no reverse lookup; IP addresses are used only in memory for rate limits and are not written to the database; after a rename the old name points to you for 30 days; a name not renewed for 6 months is deleted; "Release" or Emergency wipe deletes it at once; a banned key's name is removed; database backups are kept 14 days. Keep each claim true to Tasks 3–5 (CLAUDE.md: legal claims are checked against the code).

- [ ] **Step 2: Store disclosures**

In `store-disclosures.md` App Privacy: "User ID — collected, linked to the user, not used for tracking, purpose: App Functionality, optional"; Google Play Data safety: "User IDs — collected, optional, not shared, can be deleted (Release)".

- [ ] **Step 3: Share page**

`D:/projects/landing/public/u.html` — a small static page in the site's style (copy the `<head>` and colours from `public/terms.html`): reads `location.hash.slice(1)`, validates it against `^[a-z0-9_]{3,20}$` (otherwise shows a neutral "cubechat" page), and shows "@name", "Знайдіть @name у cubechat: Профіль → Моя картка → введіть @name" and links to the App Store / APK download already linked from the main page. No script loads anything from the network (the name never leaves the browser).

Update `public/privacy.html` with the same section as Step 1 (uk text).

- [ ] **Step 4: Commit both repos (ask the owner before pushing the landing repo — publishing public content)**

```bash
git add docs/legal/privacy-policy.uk.md docs/legal/privacy-policy.en.md docs/legal/store-disclosures.md
git commit -m "Say in the privacy policy exactly what Cube ID keeps, for how long, and how to remove it"
```

In `D:/projects/landing`: `git add public/u.html public/privacy.html && git commit -m "Give a shared @name a page to land on, and add Cube ID to the privacy policy"`; push after the owner's yes and check `https://cubechat.tech/u.html#dima` renders.

---

### Task 13: End-to-end check on two phones

**Files:** none (verification only).

- [ ] **Step 1: Full suites**

Run: `cd id && node --test`; `flutter test --exclude-tags golden`; `flutter analyze` (grep both separators). Expected: all green, 0 errors/warnings.

- [ ] **Step 2: Live server smoke test from this machine**

Run: `curl -s https://id.cubechat.tech/health` → names count; `curl -s https://id.cubechat.tech/v1/available/zz_probe_name` → `{"available":true}`.

- [ ] **Step 3: Hand the owner these exact steps (in Russian) with the next build**

1. Телефон А: Профіль → Cube ID → введи имя → «Зайняти» → видно `@имя`.
2. Телефон Б: Моя картка → в поле введи `@имя` → открывается чат → напиши «привет».
3. Телефон А: сообщение пришло; в профиле собеседника виден никнейм.
4. Телефон А: Приватність → «Через запит». Телефон В (или Б после «Видалити» чата на А): найти `@имя`, написать → на А сообщение в «Запити», у отправителя нет «прочитано».
5. Телефон А: «Ніхто» → с Б поиск `@имя` пишет «Нікого з таким @ім’ям».
6. Телефон А: сменить имя → старое находит его ещё (30 дней).

Build the APK/IPA only when the owner asks (release-build skill), bumping version and stamp then.

---

## Self-review notes

- Spec §1 (server, data, ops, reading, terms, moderation, health) → Tasks 1–5; §2 (profile, maintenance, lookup, wipe) → Tasks 8, 11; §3 (reach + requests) → Tasks 9–10; §5 legal → Task 12; §6 tests → per task + Task 13. §4 (e-mail) intentionally excluded.
- Spec deviations recorded in the spec itself (2026-09-29): no new report context; bans revoke names; no media hold for requests; request decided on arrival.
- Types used across tasks: `CubeIdResult`/`CubeIdOk`/`CubeIdRefused`/`CubeIdOffline` (Task 7) in Tasks 8 and 11; `LookupFound/LookupNotFound/LookupOffline` (Task 8) in Task 11; `StrangerReach` + `wire` (Task 9) in Tasks 8 and 11; `messageRequestsProvider` (Task 9) in Task 10.
