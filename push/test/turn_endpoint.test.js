import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import test from 'node:test';
import { schnorr } from '@noble/curves/secp256k1';
import { handleTurn, server } from '../src/index.js';

const now = 1789000000;
const options = { nowSeconds: now, secret: 'test-secret',
  urls: ['turn:example.com:3478?transport=udp'] };
function signed({ tags = [['action', 'turn']], createdAt = now } = {}) {
  const key = '01'.repeat(32);
  const event = { pubkey: Buffer.from(schnorr.getPublicKey(key)).toString('hex'),
    created_at: createdAt, kind: 24242, tags, content: '' };
  event.id = createHash('sha256').update(JSON.stringify([
    0, event.pubkey, event.created_at, event.kind, event.tags, event.content,
  ])).digest('hex');
  event.sig = Buffer.from(schnorr.sign(event.id, key)).toString('hex');
  return event;
}

test('a signed request gets short-lived access and configured listeners', () => {
  const result = handleTurn(signed(), options);
  assert.equal(result.status, 200);
  assert.equal(result.body.username, String(now + 600));
  assert.deepEqual(result.body.urls, options.urls);
  assert.equal(JSON.stringify(result).includes(options.secret), false);
});

test('registration proofs, forged signatures and stale requests are refused', () => {
  for (const event of [null, {}, signed({ tags: [] }),
    { ...signed(), content: 'tampered' }, signed({ createdAt: now - 301 }),
    signed({ createdAt: now + 301 })]) {
    assert.equal(handleTurn(event, options).status, 401);
  }
});

test('missing relay configuration never produces usable-looking credentials', () => {
  for (const config of [{ secret: '' }, { urls: [] }, { urls: ['https://example.com'] }]) {
    assert.equal(handleTurn(signed(), { ...options, ...config }).status, 503);
  }
});

test('the HTTP route refuses unsigned access and remains importable without side effects', async () => {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  try {
    const endpoint = `http://127.0.0.1:${server.address().port}`;
    const response = await fetch(`${endpoint}/turn`, { method: 'POST',
      headers: { 'content-type': 'application/json' }, body: '{}' });
    assert.equal(response.status, 401);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    const health = await fetch(`${endpoint}/health`);
    assert.equal(health.status, 200);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
