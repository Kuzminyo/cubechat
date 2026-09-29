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
  return { r, advance: (s) => { now += s; } };
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
