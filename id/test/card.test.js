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
