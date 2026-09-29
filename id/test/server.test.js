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

test('admin revoke with the token frees the name', async (t) => {
  const { base, server, registry } = await start();
  t.after(() => server.close());
  const card = b64u(cardFor(nostrPub(A)));
  await post(`${base}/v1/op`, signedOp({ op: 'claim', name: 'dima', card }, { key: A }));
  const r = await post(`${base}/admin/revoke`, { name: 'dima', reason: 'offensive' }, { authorization: 'Bearer secret' });
  assert.deepEqual(await r.json(), { revoked: 1 });
  assert.equal(registry.lookup('dima'), null);
});

test('junk carrying somebody else\'s key does not use up their claims', async (t) => {
  const { base, server } = await start();
  t.after(() => server.close());
  const victim = nostrPub(A);
  for (let i = 0; i < 6; i++) {
    const forged = { ...signedOp({ op: 'claim', name: `junk_${i}`, card: 'x' }, { key: '03'.repeat(32), powBits: 0 }), pubkey: victim };
    await post(`${base}/v1/op`, forged, { 'x-forwarded-for': `10.0.0.${i}` });
  }
  const card = b64u(cardFor(victim));
  const r = await post(`${base}/v1/op`, signedOp({ op: 'claim', name: 'dima', card }, { key: A }), { 'x-forwarded-for': '10.1.1.1' });
  assert.equal(r.status, 200);
});

test('health reports the count', async (t) => {
  const { base, server } = await start();
  t.after(() => server.close());
  const health = await (await fetch(`${base}/health`)).json();
  assert.equal(health.ok, true);
  assert.equal(health.names, 0);
});
