import assert from 'node:assert/strict';
import test from 'node:test';
import { schnorr } from '@noble/curves/secp256k1';
import { sha256 } from '@noble/hashes/sha256';
import { bytesToHex, utf8ToBytes } from '@noble/hashes/utils';

import { authorise, AuthError } from '../src/auth.js';

const KEY = '02'.repeat(32);
const OTHER = '03'.repeat(32);

function signed({ key = KEY, tags = [], at = Math.floor(Date.now() / 1000) }) {
  const event = {
    pubkey: bytesToHex(schnorr.getPublicKey(key)),
    created_at: at,
    kind: 24242,
    tags,
    content: '',
  };
  event.id = bytesToHex(
    sha256(
      utf8ToBytes(
        JSON.stringify([
          0,
          event.pubkey,
          event.created_at,
          event.kind,
          event.tags,
          event.content,
        ]),
      ),
    ),
  );
  event.sig = bytesToHex(schnorr.sign(event.id, key));
  return event;
}

const now = () => Date.now() / 1000;

test('a signed event authorises as the key that signed it', () => {
  const event = signed({ tags: [['op', 'balance']] });
  const claim = authorise(event, { now: now() });
  assert.equal(claim.npub, bytesToHex(schnorr.getPublicKey(KEY)));
  assert.equal(claim.op, 'balance');
});

test('an event claiming somebody else is refused', () => {
  // Without this the wallet answers for any key anybody names.
  const event = signed({ tags: [['op', 'balance']] });
  event.pubkey = bytesToHex(schnorr.getPublicKey(OTHER));
  assert.throws(
    () => authorise(event, { now: now() }),
    (e) => e instanceof AuthError && e.code === 'signature',
  );
});

test('a tag edited after signing is refused', () => {
  // Tags carry the operation and its arguments, so a tag that is not covered
  // by the signature is an amount anybody on the path can change.
  const event = signed({ tags: [['op', 'transfer'], ['amount', '1']] });
  event.tags = [['op', 'transfer'], ['amount', '1000']];
  assert.throws(
    () => authorise(event, { now: now() }),
    (e) => e.code === 'signature',
  );
});

test('a stale event is refused', () => {
  // A signed request is a bearer token until it expires. Without a window, one
  // overheard today works forever.
  const event = signed({ tags: [['op', 'balance']], at: Math.floor(now()) - 3600 });
  assert.throws(
    () => authorise(event, { now: now() }),
    (e) => e.code === 'stale',
  );
});

test('an event from the future is refused just as firmly', () => {
  // Otherwise a clock set forward mints a request that stays valid for as long
  // as the skew.
  const event = signed({ tags: [['op', 'balance']], at: Math.floor(now()) + 3600 });
  assert.throws(
    () => authorise(event, { now: now() }),
    (e) => e.code === 'stale',
  );
});

test('a little clock skew is tolerated in both directions', () => {
  for (const shift of [-100, 100]) {
    const event = signed({
      tags: [['op', 'balance']],
      at: Math.floor(now()) + shift,
    });
    assert.equal(authorise(event, { now: now() }).op, 'balance');
  }
});

test('an event with no op is refused rather than defaulted', () => {
  assert.throws(
    () => authorise(signed({ tags: [] }), { now: now() }),
    (e) => e.code === 'op',
  );
});

test('a malformed event is refused without throwing something else', () => {
  for (const bad of [null, {}, { pubkey: 'x' }, { ...signed({}), sig: 'zz' }]) {
    assert.throws(
      () => authorise(bad, { now: now() }),
      (e) => e instanceof AuthError,
      `accepted ${JSON.stringify(bad)}`,
    );
  }
});

test('tag values are readable by name', () => {
  const event = signed({
    tags: [['op', 'transfer'], ['to', 'c'.repeat(64)], ['amount', '4']],
  });
  const claim = authorise(event, { now: now() });
  assert.equal(claim.tag('amount'), '4');
  assert.equal(claim.tag('nothing'), null);
});
