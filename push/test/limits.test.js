import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { schnorr } from '@noble/curves/secp256k1';

// Registrations here are real ones, and the registry saves itself to
// STORE_PATH — which defaults to ./tokens.json, a deployment's file. Each test
// file is its own process, so this reaches only this one.
process.env.STORE_PATH = join(tmpdir(), `cubechat-push-test-${process.pid}.json`);
const {
  clientIpOf, createRateLimiter, handleRegister, handleReport, handleTurn,
  wakeFilters,
} = await import('../src/index.js');

const now = Math.floor(Date.now() / 1000);
const noBans = { isBannedNpub: () => false };

function signed({ key = randomBytes(32).toString('hex'), tags = [], content = '' } = {}) {
  const event = { pubkey: Buffer.from(schnorr.getPublicKey(key)).toString('hex'),
    created_at: now, kind: 24242, tags, content };
  event.id = createHash('sha256').update(JSON.stringify([
    0, event.pubkey, event.created_at, event.kind, event.tags, event.content,
  ])).digest('hex');
  event.sig = Buffer.from(schnorr.sign(event.id, key)).toString('hex');
  return event;
}

const fcmToken = 'f'.repeat(140);
const registration = (key) => signed({ key, content: fcmToken, tags: [['platform', 'android']] });

test('new npubs from one address are rate limited, refreshes are not', () => {
  const limiter = createRateLimiter({ perKey: 2, total: 100 });
  const options = { bans: noBans, ip: '203.0.113.7', limiter, nowSeconds: now };
  const keys = [1, 2, 3].map(() => randomBytes(32).toString('hex'));

  assert.equal(handleRegister(registration(keys[0]), options).ok, true);
  assert.equal(handleRegister(registration(keys[1]), options).ok, true);
  const third = handleRegister(registration(keys[2]), options);
  assert.equal(third.status, 429);

  // The two already registered keep refreshing on every launch.
  for (let i = 0; i < 5; i++) {
    assert.equal(handleRegister(registration(keys[0]), options).ok, true);
  }
  // Another address is not held up by this one.
  assert.equal(handleRegister(registration(keys[2]),
    { ...options, ip: '198.51.100.9' }).ok, true);
  // Leave the shared registry as it was.
  for (const key of keys) handleRegister(signed({ key }), options);
});

test('a full registry refuses new npubs but keeps refreshing old ones', () => {
  const limiter = createRateLimiter({ perKey: 100, total: 100 });
  const options = { bans: noBans, ip: '203.0.113.8', limiter, nowSeconds: now };
  const kept = randomBytes(32).toString('hex');
  assert.equal(handleRegister(registration(kept), options).ok, true);

  const full = { ...options, maxTokens: 0 };
  assert.equal(handleRegister(registration(randomBytes(32).toString('hex')), full).status, 503);
  assert.equal(handleRegister(registration(kept), full).ok, true);
  handleRegister(signed({ key: kept }), options);
});

test('the wake subscription is split so no REQ outgrows a relay', () => {
  const npubs = Array.from({ length: 1201 }, (_, i) => i.toString(16).padStart(64, '0'));
  const filters = wakeFilters(npubs, 5);
  assert.deepEqual(filters.map((f) => f['#p'].length), [500, 500, 201]);
  assert.deepEqual(filters.flatMap((f) => f['#p']), npubs);
  for (const f of filters) {
    assert.ok(JSON.stringify(['REQ', 'wake-0', f]).length < 64 * 1024);
    assert.deepEqual(f['#w'], ['1']);
    assert.equal(f.since, 5);
  }
});

test('TURN logins are rate limited per address and per key', () => {
  const options = { nowSeconds: now, secret: 's', urls: ['turn:example.com:3478'],
    bans: noBans, limiter: createRateLimiter({ perKey: 2, total: 1000 }) };
  const key = randomBytes(32).toString('hex');
  const turn = (k) => signed({ key: k, tags: [['action', 'turn']] });

  assert.equal(handleTurn(turn(key), { ...options, ip: 'a' }).status, 200);
  assert.equal(handleTurn(turn(key), { ...options, ip: 'b' }).status, 200);
  // Same key, third address: the key is spent.
  assert.equal(handleTurn(turn(key), { ...options, ip: 'c' }).status, 429);
  // Fresh keys from one address: the address is spent after two.
  assert.equal(handleTurn(turn(randomBytes(32).toString('hex')), { ...options, ip: 'd' }).status, 200);
  assert.equal(handleTurn(turn(randomBytes(32).toString('hex')), { ...options, ip: 'd' }).status, 200);
  assert.equal(handleTurn(turn(randomBytes(32).toString('hex')), { ...options, ip: 'd' }).status, 429);
});

function memoryStore(openCount = 0) {
  const appended = [];
  return {
    appended,
    async open() { return Array.from({ length: openCount }); },
    async append(report) { appended.push(report); return { ...report, seq: appended.length }; },
  };
}

const report = (key) => signed({ key, tags: [['action', 'report']],
  content: JSON.stringify({ reason: 'spam', context: 'general' }) });

test('fresh keys from one address cannot spend the service-wide report quota', async () => {
  const limiter = createRateLimiter({ perKey: 10, total: 200 });
  const ipLimiter = createRateLimiter({ perKey: 3, total: Infinity });
  const store = memoryStore();
  const options = { nowSeconds: now, limiter, ipLimiter, store };

  for (let i = 0; i < 3; i++) {
    const r = await handleReport(report(randomBytes(32).toString('hex')), { ...options, ip: 'spam' });
    assert.equal(r.status, 200);
  }
  const blocked = await handleReport(report(randomBytes(32).toString('hex')), { ...options, ip: 'spam' });
  assert.equal(blocked.status, 429);
  const real = await handleReport(report(randomBytes(32).toString('hex')), { ...options, ip: 'phone' });
  assert.equal(real.status, 200);
});

test('a full queue of open reports refuses more', async () => {
  const store = memoryStore(5);
  const result = await handleReport(report(randomBytes(32).toString('hex')), {
    nowSeconds: now, limiter: createRateLimiter(), store, maxOpen: 5 });
  assert.equal(result.status, 503);
  assert.equal(store.appended.length, 0);
});

test('the client address is believed only from loopback', () => {
  const request = (peer, forwarded) => ({ socket: { remoteAddress: peer },
    headers: forwarded ? { 'x-forwarded-for': forwarded } : {} });
  assert.equal(clientIpOf(request('127.0.0.1', '203.0.113.5')), '203.0.113.5');
  assert.equal(clientIpOf(request('::ffff:127.0.0.1', '203.0.113.5, 10.0.0.1')), '203.0.113.5');
  assert.equal(clientIpOf(request('198.51.100.1', '1.2.3.4')), '198.51.100.1');
  assert.equal(clientIpOf(request('127.0.0.1')), '127.0.0.1');
});
