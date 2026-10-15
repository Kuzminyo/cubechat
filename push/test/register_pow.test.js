import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { schnorr } from '@noble/curves/secp256k1';

// Registrations here are real ones, and the registry saves itself to
// STORE_PATH — a deployment's file by default. Each test file is its own
// process, so this reaches only this one.
process.env.STORE_PATH = join(tmpdir(), `cubechat-push-pow-test-${process.pid}.json`);
const { createRateLimiter, difficulty, handleRegister } = await import('../src/index.js');

const now = Math.floor(Date.now() / 1000);
const noBans = { isBannedNpub: () => false };
const fcmToken = 'f'.repeat(140);
const baseTags = [['lang', 'uk'], ['platform', 'android']];

const idOf = (event) => createHash('sha256').update(JSON.stringify([
  0, event.pubkey, event.created_at, event.kind, event.tags, event.content,
])).digest('hex');

// The app's shape: its own tags first, the NIP-13 nonce tag appended last
// (mineNonce in lib/core/transport/nostr/nostr_pow.dart).
function signed(key, { content = fcmToken, bits = 0 } = {}) {
  const event = { pubkey: Buffer.from(schnorr.getPublicKey(key)).toString('hex'),
    created_at: now, kind: 24242, tags: baseTags, content };
  if (bits > 0) {
    for (let nonce = 0; ; nonce++) {
      event.tags = [...baseTags, ['nonce', String(nonce), String(bits)]];
      if (difficulty(idOf(event)) >= bits) break;
    }
  }
  event.id = idOf(event);
  event.sig = Buffer.from(schnorr.sign(event.id, key)).toString('hex');
  return event;
}

const forget = (key) => handleRegister(signed(key, { content: '' }), { bans: noBans, nowSeconds: now });

test('difficulty counts leading zero bits of the id', () => {
  assert.equal(difficulty('f'.repeat(64)), 0);
  assert.equal(difficulty('0'.repeat(3) + '1' + 'f'.repeat(60)), 15);
  assert.equal(difficulty('00' + '7' + 'f'.repeat(61)), 9);
  assert.equal(difficulty('0'.repeat(64)), 256);
});

test('a first registration without work is refused, and spends no quota', () => {
  // One new npub per address: if the refusal spent it, the mined retry below
  // would be refused for rate instead.
  const limiter = createRateLimiter({ perKey: 1, total: 100 });
  const options = { bans: noBans, ip: '203.0.113.20', limiter, nowSeconds: now,
    powBits: 8, powFreeBelow: 0 };
  const key = randomBytes(32).toString('hex');

  const refused = handleRegister(signed(key), options);
  assert.equal(refused.ok, false);
  assert.equal(refused.reason, 'pow');
  assert.equal(refused.status, 403);
  // The app mines to what it is told, so a raise needs no release.
  assert.equal(refused.bits, 8);

  assert.equal(handleRegister(signed(key, { bits: 8 }), options).ok, true);
  forget(key);
});

test('a registered phone refreshes without work, however full the registry', () => {
  const limiter = createRateLimiter({ perKey: 100, total: 100 });
  const free = { bans: noBans, ip: '203.0.113.21', limiter, nowSeconds: now };
  const key = randomBytes(32).toString('hex');
  assert.equal(handleRegister(signed(key), free).ok, true);

  const strict = { ...free, powBits: 20, powFreeBelow: 0 };
  for (let i = 0; i < 3; i++) {
    assert.equal(handleRegister(signed(key), strict).ok, true);
  }
  // And it can still leave: forgetting never asks for work.
  assert.deepEqual(handleRegister(signed(key, { content: '' }), strict),
    { ok: true, registered: false });
});

test('below the watermark an old build registers without work', () => {
  const limiter = createRateLimiter({ perKey: 100, total: 100 });
  const options = { bans: noBans, ip: '203.0.113.22', limiter, nowSeconds: now,
    powBits: 20, powFreeBelow: 1_000_000 };
  const key = randomBytes(32).toString('hex');
  assert.equal(handleRegister(signed(key), options).ok, true);
  forget(key);
});

test('too little work is refused as no work', () => {
  const limiter = createRateLimiter({ perKey: 100, total: 100 });
  const options = { bans: noBans, ip: '203.0.113.23', limiter, nowSeconds: now,
    powBits: 12, powFreeBelow: 0 };
  let event;
  // Mined to 4, but not by luck to 12 — a fresh key until it is not.
  do {
    event = signed(randomBytes(32).toString('hex'), { bits: 4 });
  } while (difficulty(event.id) >= 12);
  assert.equal(handleRegister(event, options).reason, 'pow');
});
