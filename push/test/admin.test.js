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

const { handleAdmin, server, createReportStore } = await import('../src/index.js');

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
    // Mirrors the real store's atomic decide: check-and-set with no `await`
    // in between, so this fake is race-free too (a real concurrency test
    // uses the actual queued `createReportStore`, further down).
    async decide(id, patch) {
      const existing = reports.get(id);
      if (!existing) return { notFound: true };
      if (existing.status !== 'open') return { conflict: existing.status };
      const updated = { ...existing, ...patch };
      reports.set(id, updated);
      return { report: updated };
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

test('a non-numeric or negative since is refused as 400 rather than silently treated as 0', async () => {
  const store = fakeStore([{ id: 'a', seq: 1, status: 'open' }]);
  for (const since of ['abc', '-1', '1.5', 'NaN']) {
    const result = await handleAdmin(
      req({ url: `/admin/reports?since=${since}`, headers: { authorization: `Bearer ${TOKEN}` } }),
      { adminToken: TOKEN, remoteAddress: LOCAL, store, bans: fakeBans() },
    );
    assert.equal(result.status, 400, `since=${since} should be refused`);
    assert.equal(result.body.reason, 'since');
  }
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

// The race S2 review round 1 flagged: reading a report's status and later
// writing a decision, as two separate steps, let two concurrent decisions
// both see 'open' and both return 200. These use the real, queue-backed
// `createReportStore` rather than the fake above, because the fake's
// check-and-set already happens with no `await` in between and so can't
// reproduce the race a truly concurrent pair of `handleAdmin` calls exercises
// against the real store's `enqueue`d `decide`.
test('two concurrent bans on one report: exactly one wins, bans.ban runs once', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cubechat-admin-race-'));
  const store = createReportStore(path.join(dir, 'reports.jsonl'));
  await store.append({ id: 'r1', status: 'open', reason: 'spam' });
  const bans = fakeBans();
  const call = () => handleAdmin(
    req({ method: 'POST', url: '/admin/reports/r1/ban', headers: { authorization: `Bearer ${TOKEN}` } }),
    { adminToken: TOKEN, remoteAddress: LOCAL, store, bans },
  );
  const [a, b] = await Promise.all([call(), call()]);
  assert.deepEqual([a.status, b.status].sort(), [200, 409]);
  assert.equal(bans.banned.length, 1, 'bans.ban must run exactly once');
  assert.equal((await store.get('r1')).status, 'banned');
});

test('a concurrent ban and dismiss on one report: exactly one wins, the other is 409', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cubechat-admin-race-'));
  const store = createReportStore(path.join(dir, 'reports.jsonl'));
  await store.append({ id: 'r1', status: 'open', reason: 'spam' });
  const bans = fakeBans();
  const ban = handleAdmin(
    req({ method: 'POST', url: '/admin/reports/r1/ban', headers: { authorization: `Bearer ${TOKEN}` } }),
    { adminToken: TOKEN, remoteAddress: LOCAL, store, bans },
  );
  const dismiss = handleAdmin(
    req({ method: 'POST', url: '/admin/reports/r1/dismiss', headers: { authorization: `Bearer ${TOKEN}` } }),
    { adminToken: TOKEN, remoteAddress: LOCAL, store, bans },
  );
  const [banResult, dismissResult] = await Promise.all([ban, dismiss]);
  assert.deepEqual([banResult.status, dismissResult.status].sort(), [200, 409]);
  // Whichever one won decided the final status; either is a legitimate
  // outcome of a genuine race, so this only checks that exactly one did.
  const finalStatus = (await store.get('r1')).status;
  assert.ok(['banned', 'dismissed'].includes(finalStatus));
  assert.equal(bans.banned.length, finalStatus === 'banned' ? 1 : 0);
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
  // calling :8080 directly — but Caddy always adds X-Forwarded-For, and the
  // bot never does. Via is checked too, defensively, though Caddy doesn't set
  // it by default here.
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

    // The 400 path (a malformed `since`) is uncacheable too — every /admin/
    // response is, not just the 200s.
    const badSince = await fetch(`${endpoint}/admin/reports?since=abc`, {
      headers: { authorization: `Bearer ${TOKEN}` },
    });
    assert.equal(badSince.status, 400);
    assert.equal(badSince.headers.get('cache-control'), 'no-store');
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
