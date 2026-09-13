import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import test from 'node:test';
import { schnorr } from '@noble/curves/secp256k1';
import { server } from '../src/index.js';

function signed({ tags, content = '' }) {
  const key = '02'.repeat(32);
  const event = { pubkey: Buffer.from(schnorr.getPublicKey(key)).toString('hex'),
    created_at: Math.floor(Date.now() / 1000), kind: 24242, tags, content };
  event.id = createHash('sha256').update(JSON.stringify([
    0, event.pubkey, event.created_at, event.kind, event.tags, event.content,
  ])).digest('hex');
  event.sig = Buffer.from(schnorr.sign(event.id, key)).toString('hex');
  return event;
}

async function post(path, body) {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  try {
    const response = await fetch(`http://127.0.0.1:${server.address().port}${path}`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body) });
    return { status: response.status, body: await response.json() };
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

// A request for TURN access is the same kind as a registration and carries
// empty content — which is exactly how a phone asks /register to forget it.
// Without this refusal, anyone holding one phone's TURN request could replay
// it at /register and silently switch that phone's notifications off.
test('a TURN request replayed at /register does not unregister anybody', async () => {
  const result = await post('/register', signed({ tags: [['action', 'turn']] }));
  assert.equal(result.status, 400);
  assert.equal(result.body.ok, false);
  assert.equal(result.body.reason, 'purpose');
});

test('an ordinary unregistration, which carries no purpose tag, is still accepted', async () => {
  const result = await post('/register', signed({
    tags: [['lang', 'en'], ['platform', 'ios']] }));
  assert.equal(result.status, 200);
  assert.equal(result.body.ok, true);
});
