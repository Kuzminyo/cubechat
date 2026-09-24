import assert from 'node:assert/strict';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { once } from 'node:events';
import path from 'node:path';
import test from 'node:test';

// This file's copy of the server must not share `reports.jsonl` with any
// other test file (Node's test runner puts each file in its own process, so
// setting env before the dynamic import below is enough), and it needs its
// own fixed ADMIN_TOKEN so the HTTP-wiring test can authenticate.
const reportsDir = await mkdtemp(path.join(tmpdir(), 'cubechat-admin-reports-'));
process.env.REPORTS_PATH = path.join(reportsDir, 'reports.jsonl');
process.env.ADMIN_TOKEN = 'test-admin-token';

const { handleAdmin, server } = await import('../src/index.js');

const TOKEN = 'test-admin-token';
const LOCAL = '127.0.0.1';

function fakeStore(initial = []) {
  const reports = new Map(initial.map((r) => [r.id, { ...r }]));
  return {
    async get(id) {
      return reports.get(id) ?? null;
    },
    async update(id, patch) {
      const existing = reports.get(id);
      if (!existing) return null;
      const updated = { ...existing, ...patch };
      reports.set(id, updated);
      return updated;
    },
    async open() {
      return [...reports.values()].filter((r) => r.status === 'open').sort((a, b) => a.seq - b.seq);
    },
    async since(seq) {
      const rest = [...reports.values()].filter((r) => r.seq > seq).sort((a, b) => a.seq - b.seq);
      const next = rest.length ? rest[rest.length - 1].seq : seq;
      return { reports: rest, next };
    },
  };
}

function fakeBans({ banFails = false, unbanFails = false } = {}) {
  const banned = [];
  const unbanned = [];
  return {
    banned,
    unbanned,
    async ban(report) {
      if (banFails) throw new Error('boom');
      banned.push(report);
    },
    async unban(key) {
      if (unbanFails) throw new Error('boom');
      unbanned.push(key);
      return key === 'known-key';
    },
  };
}

function req({ method = 'GET', url, headers = {}, body = '' } = {}) {
  return { method, url, headers, body };
}

test('GET /admin/reports?since= returns only newer reports and the right next', async () => {
  const store = fakeStore([
    { id: 'a', seq: 1, status: 'open' },
    { id: 'b', seq: 2, status: 'open' },
    { id: 'c', seq: 3, status: 'dismissed' },
  ]);
  const result = await handleAdmin(
    req({ url: '/admin/reports?since=1', headers: { authorization: `Bearer ${TOKEN}` } }),
    { adminToken: TOKEN, remoteAddress: LOCAL, store, bans: fakeBans() },
  );
  assert.equal(result.status, 200);
  assert.deepEqual(result.body.reports.map((r) => r.id), ['b', 'c']);
  assert.equal(result.body.next, 3);
});

test('GET /admin/reports with no since returns everything', async () => {
  const store = fakeStore([{ id: 'a', seq: 1, status: 'open' }, { id: 'b', seq: 2, status: 'banned' }]);
  const result = await handleAdmin(
    req({ url: '/admin/reports', headers: { authorization: `Bearer ${TOKEN}` } }),
    { adminToken: TOKEN, remoteAddress: LOCAL, store, bans: fakeBans() },
  );
  assert.equal(result.status, 200);
  assert.deepEqual(result.body.reports.map((r) => r.id), ['a', 'b']);
});

test('GET /admin/reports?status=open returns only open reports', async () => {
  const store = fakeStore([
    { id: 'a', seq: 1, status: 'open' },
    { id: 'b', seq: 2, status: 'banned' },
    { id: 'c', seq: 3, status: 'open' },
  ]);
  const result = await handleAdmin(
    req({ url: '/admin/reports?status=open', headers: { authorization: `Bearer ${TOKEN}` } }),
    { adminToken: TOKEN, remoteAddress: LOCAL, store, bans: fakeBans() },
  );
  assert.equal(result.status, 200);
  assert.deepEqual(result.body.reports.map((r) => r.id), ['a', 'c']);
});

test('POST /admin/reports/<id>/ban calls bans.ban, sets status, and persists through store.update', async () => {
  const store = fakeStore([{ id: 'a', seq: 1, status: 'open', reason: 'spam' }]);
  const bans = fakeBans();
  const result = await handleAdmin(
    req({ method: 'POST', url: '/admin/reports/a/ban', headers: { authorization: `Bearer ${TOKEN}` } }),
    { adminToken: TOKEN, remoteAddress: LOCAL, store, bans },
  );
  assert.equal(result.status, 200);
  assert.equal(result.body.ok, true);
  assert.equal(result.body.report.status, 'banned');
  assert.equal(bans.banned.length, 1);
  assert.equal(bans.banned[0].id, 'a');
  assert.equal((await store.get('a')).status, 'banned');
});

test('POST /admin/reports/<id>/dismiss sets status and persists', async () => {
  const store = fakeStore([{ id: 'a', seq: 1, status: 'open' }]);
  const result = await handleAdmin(
    req({ method: 'POST', url: '/admin/reports/a/dismiss', headers: { authorization: `Bearer ${TOKEN}` } }),
    { adminToken: TOKEN, remoteAddress: LOCAL, store, bans: fakeBans() },
  );
  assert.equal(result.status, 200);
  assert.equal(result.body.report.status, 'dismissed');
  assert.equal((await store.get('a')).status, 'dismissed');
});

test('a report already decided is refused with 409 and its current status', async () => {
  const store = fakeStore([{ id: 'a', seq: 1, status: 'banned' }]);
  const result = await handleAdmin(
    req({ method: 'POST', url: '/admin/reports/a/dismiss', headers: { authorization: `Bearer ${TOKEN}` } }),
    { adminToken: TOKEN, remoteAddress: LOCAL, store, bans: fakeBans() },
  );
  assert.equal(result.status, 409);
  assert.equal(result.body.status, 'banned');
});

test('an unknown report id is 404', async () => {
  const store = fakeStore([]);
  const result = await handleAdmin(
    req({ method: 'POST', url: '/admin/reports/nope/ban', headers: { authorization: `Bearer ${TOKEN}` } }),
    { adminToken: TOKEN, remoteAddress: LOCAL, store, bans: fakeBans() },
  );
  assert.equal(result.status, 404);
  assert.equal(result.body.reason, 'no such report');
});

test('a ban whose bans.ban rejects is 503 and the report stays open', async () => {
  const store = fakeStore([{ id: 'a', seq: 1, status: 'open' }]);
  const bans = fakeBans({ banFails: true });
  const result = await handleAdmin(
    req({ method: 'POST', url: '/admin/reports/a/ban', headers: { authorization: `Bearer ${TOKEN}` } }),
    { adminToken: TOKEN, remoteAddress: LOCAL, store, bans },
  );
  assert.equal(result.status, 503);
  assert.equal(result.body.reason, 'bans unavailable');
  assert.equal((await store.get('a')).status, 'open');
});

test('POST /admin/unban calls bans.unban with the key and reports whether it was removed', async () => {
  const store = fakeStore([]);
  const bans = fakeBans();
  const removed = await handleAdmin(
    req({
      method: 'POST', url: '/admin/unban', headers: { authorization: `Bearer ${TOKEN}` },
      body: JSON.stringify({ key: 'known-key' }),
    }),
    { adminToken: TOKEN, remoteAddress: LOCAL, store, bans },
  );
  assert.equal(removed.status, 200);
  assert.equal(removed.body.ok, true);

  const notRemoved = await handleAdmin(
    req({
      method: 'POST', url: '/admin/unban', headers: { authorization: `Bearer ${TOKEN}` },
      body: JSON.stringify({ key: 'other-key' }),
    }),
    { adminToken: TOKEN, remoteAddress: LOCAL, store, bans },
  );
  assert.equal(notRemoved.status, 200);
  assert.equal(notRemoved.body.ok, false);
  assert.deepEqual(bans.unbanned, ['known-key', 'other-key']);
});

test('an unban whose bans.unban rejects is 503', async () => {
  const store = fakeStore([]);
  const bans = fakeBans({ unbanFails: true });
  const result = await handleAdmin(
    req({
      method: 'POST', url: '/admin/unban', headers: { authorization: `Bearer ${TOKEN}` },
      body: JSON.stringify({ key: 'k' }),
    }),
    { adminToken: TOKEN, remoteAddress: LOCAL, store, bans },
  );
  assert.equal(result.status, 503);
  assert.equal(result.body.reason, 'bans unavailable');
});

test('a missing or wrong token is 404, indistinguishable from an unknown route', async () => {
  const store = fakeStore([{ id: 'a', seq: 1, status: 'open' }]);
  for (const headers of [{}, { authorization: 'Bearer wrong-token' }, { authorization: 'not-bearer-at-all' }]) {
    const result = await handleAdmin(
      req({ url: '/admin/reports', headers }),
      { adminToken: TOKEN, remoteAddress: LOCAL, store, bans: fakeBans() },
    );
    assert.equal(result.status, 404);
  }
});

test('the right token from a non-local address is still 404', async () => {
  const store = fakeStore([]);
  const result = await handleAdmin(
    req({ url: '/admin/reports', headers: { authorization: `Bearer ${TOKEN}` } }),
    { adminToken: TOKEN, remoteAddress: '10.0.0.5', store, bans: fakeBans() },
  );
  assert.equal(result.status, 404);
});

test('::1 and ::ffff:127.0.0.1 both count as local', async () => {
  const store = fakeStore([]);
  for (const remoteAddress of ['::1', '::ffff:127.0.0.1']) {
    const result = await handleAdmin(
      req({ url: '/admin/reports', headers: { authorization: `Bearer ${TOKEN}` } }),
      { adminToken: TOKEN, remoteAddress, store, bans: fakeBans() },
    );
    assert.equal(result.status, 200);
  }
});

test('a right token and a local address are still refused when the request carries a proxy header', async () => {
  // This is what makes the loopback check mean something: Caddy proxies every
  // public request to 127.0.0.1 too (see push/deploy/Caddyfile), so the
  // remoteAddress alone can't tell a stranger through Caddy from the bot
  // calling :8080 directly — but Caddy always adds X-Forwarded-For (and Via),
  // and the bot never does.
  const store = fakeStore([]);
  for (const headers of [
    { authorization: `Bearer ${TOKEN}`, 'x-forwarded-for': '203.0.113.9' },
    { authorization: `Bearer ${TOKEN}`, via: '1.1 caddy' },
  ]) {
    const result = await handleAdmin(
      req({ url: '/admin/reports', headers }),
      { adminToken: TOKEN, remoteAddress: LOCAL, store, bans: fakeBans() },
    );
    assert.equal(result.status, 404);
  }
});

test('with ADMIN_TOKEN unset, every route is 404 regardless of token or address', async () => {
  const store = fakeStore([{ id: 'a', seq: 1, status: 'open' }]);
  const requests = [
    req({ url: '/admin/reports', headers: { authorization: `Bearer ${TOKEN}` } }),
    req({ method: 'POST', url: '/admin/reports/a/ban', headers: { authorization: `Bearer ${TOKEN}` } }),
    req({ method: 'POST', url: '/admin/unban', headers: { authorization: `Bearer ${TOKEN}` }, body: '{"key":"k"}' }),
  ];
  for (const request of requests) {
    // Explicitly '' rather than omitted/undefined: `adminToken` defaults to
    // `process.env.ADMIN_TOKEN`, which this file sets for its own HTTP-route
    // test, so leaving it out would silently fall back to that real token
    // instead of exercising "unconfigured".
    const result = await handleAdmin(request, {
      adminToken: '', remoteAddress: LOCAL, store, bans: fakeBans(),
    });
    assert.equal(result.status, 404);
  }
});

test('the HTTP route wires request.socket.remoteAddress and the store through, end to end', async () => {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  try {
    const endpoint = `http://127.0.0.1:${server.address().port}`;

    // No token at all — refused, and not distinguishable from a 404 route.
    const bare = await fetch(`${endpoint}/admin/reports`);
    assert.equal(bare.status, 404);

    // The real token, from the loopback socket this test itself is on.
    const authed = await fetch(`${endpoint}/admin/reports`, {
      headers: { authorization: `Bearer ${TOKEN}` },
    });
    assert.equal(authed.status, 200);
    assert.equal(authed.headers.get('cache-control'), 'no-store');
    const body = await authed.json();
    assert.equal(Array.isArray(body.reports), true);

    // A spoofed X-Forwarded-For must not buy a real request admin access,
    // even carrying the right token.
    const spoofed = await fetch(`${endpoint}/admin/reports`, {
      headers: { authorization: `Bearer ${TOKEN}`, 'x-forwarded-for': '203.0.113.9' },
    });
    assert.equal(spoofed.status, 404);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
