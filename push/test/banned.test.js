import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, verify as edVerify } from 'node:crypto';
import { createServer as createHttpServer } from 'node:http';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { once } from 'node:events';
import path from 'node:path';
import test from 'node:test';
import { schnorr } from '@noble/curves/secp256k1';

// This file's copy of the server must not share `banned.json` or
// `reports.jsonl` with any other test file (Node's test runner puts each file
// in its own process, so setting env before the dynamic import below is
// enough), and it needs a real Ed25519 key pair so the signed body can
// actually be verified rather than trusted on faith.
const bansDir = await mkdtemp(path.join(tmpdir(), 'cubechat-bans-'));
process.env.BANNED_PATH = path.join(bansDir, 'banned.json');
process.env.REPORTS_PATH = path.join(bansDir, 'reports.jsonl');
process.env.ADMIN_TOKEN = 'test-admin-token';

const { publicKey, privateKey } = generateKeyPairSync('ed25519');
const pkcs8B64 = privateKey.export({ type: 'pkcs8', format: 'der' }).toString('base64');
process.env.BAN_SIGNING_KEY = pkcs8B64;

const { createBans, canonicalBanBody, handleAdmin, handleBanned, server } = await import('../src/index.js');

// Real wall-clock time, not a fixed constant: the HTTP integration test below
// exercises /turn, /report and /register through the real server route, none
// of which is given an injectable `nowSeconds` by that route — they all check
// against `Date.now()` for real. A hardcoded value would drift stale the
// moment it was written.
const now = Math.floor(Date.now() / 1000);

function verifiesWithTestKey(body) {
  return edVerify(null, Buffer.from(canonicalBanBody(body), 'utf8'), publicKey, Buffer.from(body.sig, 'hex'));
}

function reportFixture(overrides = {}) {
  return {
    id: 'r1',
    status: 'open',
    reason: 'abuse',
    context: 'direct',
    target: 'aa'.repeat(32),
    ...overrides,
  };
}

function signed({ kind = 24242, tags = [['action', 'turn']], createdAt = now, content = '' } = {}) {
  const key = '02'.repeat(32);
  const event = {
    pubkey: Buffer.from(schnorr.getPublicKey(key)).toString('hex'),
    created_at: createdAt,
    kind,
    tags,
    content,
  };
  event.id = createHash('sha256').update(JSON.stringify([
    0, event.pubkey, event.created_at, event.kind, event.tags, event.content,
  ])).digest('hex');
  event.sig = Buffer.from(schnorr.sign(event.id, key)).toString('hex');
  return event;
}

// Review round 1, item 2: a fixed cross-language vector for the app (Dart,
// Task A6) to verify its own canonicalisation and Ed25519 verify against —
// the same numbers, in the same order, as
// `.superpowers/sdd/2026-09-24-moderation-ugc/ban-canonical-vector.md`. The
// signing key here is a throwaway, generated once and hard-coded — never the
// real `BAN_SIGNING_KEY` — so this vector is reproducible by anyone reading
// this file and is safe to publish alongside its own signature.
const VECTOR_PRIVATE_KEY_PKCS8_B64 =
  'MC4CAQAwBQYDK2VwBCIEIH+86rB/X+X0edbydXmaVdEKiuCIVWxGz0EXx6nBEpe7';
const VECTOR_PUBLIC_KEY_HEX =
  'f8a3b6fc8195e23ce2a0f0f6c67d7a8ff1827843541c17b0a44f4a3f6c7dbb3a';
const VECTOR_BODY = {
  v: 1,
  updatedAt: 1700000000,
  identities: ['11'.repeat(32), '22'.repeat(32)],
  npubs: ['33'.repeat(32)],
  fingerprints: ['44'.repeat(32)],
};
const VECTOR_CANONICAL =
  '{"v":1,"updatedAt":1700000000,"identities":["1111111111111111111111111111111111111111111111111111111111111111","2222222222222222222222222222222222222222222222222222222222222222"],"npubs":["3333333333333333333333333333333333333333333333333333333333333333"],"fingerprints":["4444444444444444444444444444444444444444444444444444444444444444"]}';
const VECTOR_SIGNATURE =
  'e540f985eb8139302691f82086205a2d29b44a990e03da5b0c9d84e596ab091561be8890dfed566231b36845f52be5937355ac06450e2ca9ee17864c4e761e06';

test('the fixed cross-language vector: canonicalBanBody matches exactly, and the signature verifies', async () => {
  assert.equal(canonicalBanBody(VECTOR_BODY), VECTOR_CANONICAL);

  const dir = await mkdtemp(path.join(tmpdir(), 'cubechat-bans-vector-'));
  // `nowSeconds` is fixed 2 below the vector's `updatedAt`, not equal to it:
  // three `ban()` calls are needed to build this list (one report can only
  // add one identity-or-fingerprint plus one npub), and the monotonic
  // `max(now, previous + 1)` fix from this same review round means three
  // calls at a constant `now` land on `now, now+1, now+2` — so `now` has to
  // be `updatedAt - 2` for the third call to land exactly on `updatedAt`.
  const bans = createBans({
    path: path.join(dir, 'banned.json'),
    signingKeyPkcs8B64: VECTOR_PRIVATE_KEY_PKCS8_B64,
    nowSeconds: VECTOR_BODY.updatedAt - 2,
  });
  // Rebuild the same set of bans one report at a time, through the real
  // `ban()` path, rather than constructing the signed body by hand — this is
  // what proves `ban()` itself produces exactly the vector, not just that
  // `canonicalBanBody` can reproduce a string written by a human.
  await bans.ban({ context: 'direct', target: VECTOR_BODY.identities[0] });
  await bans.ban({ context: 'direct', target: VECTOR_BODY.identities[1], targetNpub: VECTOR_BODY.npubs[0] });
  await bans.ban({ context: 'channel', target: VECTOR_BODY.fingerprints[0] });
  const body = bans.list();
  assert.equal(canonicalBanBody(body), VECTOR_CANONICAL);
  assert.equal(body.sig, VECTOR_SIGNATURE);

  const { publicKey } = generateKeyPairSync('ed25519'); // unrelated key, just to prove verify() needs the right one
  assert.equal(
    edVerify(null, Buffer.from(VECTOR_CANONICAL, 'utf8'), publicKey, Buffer.from(VECTOR_SIGNATURE, 'hex')),
    false,
  );
});

test('canonicalBanBody sorts arrays and carries no sig', () => {
  const canonical = canonicalBanBody({
    v: 1, updatedAt: 5, identities: ['bb', 'aa'], npubs: ['zz', 'aa'], fingerprints: [],
  });
  assert.equal(canonical, JSON.stringify({
    v: 1, updatedAt: 5, identities: ['aa', 'bb'], npubs: ['aa', 'zz'], fingerprints: [],
  }));
});

test('ban(report) then list() contains the key, and the signature verifies', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cubechat-bans-unit-'));
  const bans = createBans({ path: path.join(dir, 'banned.json'), signingKeyPkcs8B64: pkcs8B64, nowSeconds: now });
  const target = 'aa'.repeat(32);
  await bans.ban(reportFixture({ target, context: 'direct' }));
  const body = bans.list();
  assert.ok(body.identities.includes(target));
  assert.equal(verifiesWithTestKey(body), true);
});

test('the signature fails to verify after any field is altered', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cubechat-bans-unit-'));
  const bans = createBans({ path: path.join(dir, 'banned.json'), signingKeyPkcs8B64: pkcs8B64, nowSeconds: now });
  await bans.ban(reportFixture({ target: 'aa'.repeat(32) }));
  const body = bans.list();
  assert.equal(verifiesWithTestKey({ ...body, updatedAt: body.updatedAt + 1 }), false);
  assert.equal(verifiesWithTestKey({ ...body, identities: [...body.identities, 'bb'.repeat(32)] }), false);
});

test('a channel report bans the fingerprint, not an identity', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cubechat-bans-unit-'));
  const bans = createBans({ path: path.join(dir, 'banned.json'), signingKeyPkcs8B64: pkcs8B64, nowSeconds: now });
  const fingerprint = 'cc'.repeat(32);
  await bans.ban(reportFixture({ context: 'channel', target: fingerprint }));
  const body = bans.list();
  assert.ok(body.fingerprints.includes(fingerprint));
  assert.equal(body.identities.includes(fingerprint), false);
});

test('targetNpub, when present, is added to npubs', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cubechat-bans-unit-'));
  const bans = createBans({ path: path.join(dir, 'banned.json'), signingKeyPkcs8B64: pkcs8B64, nowSeconds: now });
  const targetNpub = 'dd'.repeat(32);
  await bans.ban(reportFixture({ target: 'aa'.repeat(32), targetNpub }));
  const body = bans.list();
  assert.ok(body.npubs.includes(targetNpub));
  assert.equal(bans.isBannedNpub(targetNpub), true);
});

test('unban removes a key from whichever set holds it', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cubechat-bans-unit-'));
  const bans = createBans({ path: path.join(dir, 'banned.json'), signingKeyPkcs8B64: pkcs8B64, nowSeconds: now });
  const target = 'aa'.repeat(32);
  await bans.ban(reportFixture({ target }));
  assert.equal(await bans.unban(target), true);
  assert.equal(bans.list().identities.includes(target), false);
  assert.equal(await bans.unban(target), false);
});

test('a ban is persisted across a fresh createBans on the same file', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cubechat-bans-unit-'));
  const filePath = path.join(dir, 'banned.json');
  const target = 'ee'.repeat(32);
  const first = createBans({ path: filePath, signingKeyPkcs8B64: pkcs8B64, nowSeconds: now });
  await first.ban(reportFixture({ target }));

  const second = createBans({ path: filePath, signingKeyPkcs8B64: pkcs8B64, nowSeconds: now + 1 });
  assert.ok(second.list().identities.includes(target));
});

// Review round 1, critical: `nowSeconds`'s default used to be evaluated once
// at `createBans()` call time (`Math.floor(Date.now() / 1000)` as a bare
// value), so the process-lifetime `adminBans` singleton stamped every ban and
// unban with whatever second the server happened to boot in, forever. Fixed
// to a function default plus a strictly-increasing `updatedAt`; these two
// tests cover both halves of that fix.
test('with the real (function) default, updatedAt grows as real time passes', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cubechat-bans-clock-'));
  // No `nowSeconds` override at all — this is the actual default a fresh
  // `createBans()` gets, the same one `adminBans` uses in production.
  const bans = createBans({ path: path.join(dir, 'banned.json'), signingKeyPkcs8B64: pkcs8B64 });
  await bans.ban(reportFixture({ target: 'a1'.repeat(32) }));
  const first = bans.list().updatedAt;
  await new Promise((resolve) => setTimeout(resolve, 1100));
  await bans.ban(reportFixture({ id: 'r2', target: 'a2'.repeat(32) }));
  const second = bans.list().updatedAt;
  assert.ok(second > first, `expected updatedAt to grow (${first} -> ${second})`);
});

test('two changes within the same injected second still produce strictly increasing updatedAt', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cubechat-bans-clock-'));
  // A fixed number, not a function: every call to `nowSeconds()` inside
  // `createBans` would return exactly the same second, so this isolates the
  // "previous + 1" half of the fix from real wall-clock time entirely.
  const bans = createBans({ path: path.join(dir, 'banned.json'), signingKeyPkcs8B64: pkcs8B64, nowSeconds: now });
  await bans.ban(reportFixture({ target: 'b1'.repeat(32) }));
  const first = bans.list().updatedAt;
  await bans.ban(reportFixture({ id: 'r2', target: 'b2'.repeat(32) }));
  const second = bans.list().updatedAt;
  assert.equal(second, first + 1);
  await bans.ban(reportFixture({ id: 'r3', target: 'b3'.repeat(32) }));
  assert.equal(bans.list().updatedAt, first + 2);
});

test('a clock stepped backwards still can not move updatedAt backwards', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cubechat-bans-clock-'));
  const bans = createBans({ path: path.join(dir, 'banned.json'), signingKeyPkcs8B64: pkcs8B64, nowSeconds: now + 100 });
  await bans.ban(reportFixture({ target: 'c1'.repeat(32) }));
  const ahead = bans.list().updatedAt;
  assert.equal(ahead, now + 100);

  let stepped = now; // the clock corrected itself backwards by 100 seconds
  const bansAfterStep = createBans({
    path: path.join(dir, 'banned.json'), signingKeyPkcs8B64: pkcs8B64, nowSeconds: () => stepped,
  });
  await bansAfterStep.ban(reportFixture({ id: 'r2', target: 'c2'.repeat(32) }));
  assert.equal(bansAfterStep.list().updatedAt, ahead + 1);
});

test('two concurrent bans on one file do not lose either write', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cubechat-bans-unit-'));
  const filePath = path.join(dir, 'banned.json');
  const bans = createBans({ path: filePath, signingKeyPkcs8B64: pkcs8B64, nowSeconds: now });
  const a = 'a1'.repeat(32);
  const b = 'b2'.repeat(32);
  await Promise.all([
    bans.ban(reportFixture({ id: 'a', target: a })),
    bans.ban(reportFixture({ id: 'b', target: b })),
  ]);
  const body = bans.list();
  assert.ok(body.identities.includes(a));
  assert.ok(body.identities.includes(b));
});

test('handleAdmin ban wires through to a real createBans: GET /banned lists the key and verifies', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cubechat-bans-integration-'));
  const bans = createBans({ path: path.join(dir, 'banned.json'), signingKeyPkcs8B64: pkcs8B64, nowSeconds: now });
  const target = 'ff'.repeat(32);
  const store = {
    async decide(id, patch) {
      return { report: { id, status: patch.status, context: 'direct', target } };
    },
    async update() {},
  };
  const result = await handleAdmin(
    { method: 'POST', url: '/admin/reports/r1/ban', headers: { authorization: 'Bearer test-admin-token' }, body: '' },
    { adminToken: 'test-admin-token', remoteAddress: '127.0.0.1', store, bans },
  );
  assert.equal(result.status, 200);
  const body = bans.list();
  assert.ok(body.identities.includes(target));
  assert.equal(verifiesWithTestKey(body), true);
});

test('GET /banned returns the signed body with a long-lived cache header', async () => {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  try {
    const endpoint = `http://127.0.0.1:${server.address().port}`;
    const response = await fetch(`${endpoint}/banned`);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('cache-control'), 'public, max-age=300');
    const body = await response.json();
    assert.equal(body.v, 1);
    assert.equal(typeof body.sig, 'string');
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('a banned npub is refused 403 on /register and /turn, but only after its signature verifies', async () => {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  try {
    const endpoint = `http://127.0.0.1:${server.address().port}`;

    // The identity that will end up banned. /turn and /register are both
    // signed by this same key, exactly as the app signs them.
    const turnEvent = signed({ tags: [['action', 'turn']] });
    const bannedNpub = turnEvent.pubkey;

    // An unsigned /turn request for the same npub is refused for lack of a
    // signature, not because it is banned — proving the 403 path only runs
    // after verifyEvent, so an unsigned probe can't be used to test the list.
    const unsignedTurn = await fetch(`${endpoint}/turn`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ ...turnEvent, sig: '00'.repeat(64) }),
    });
    assert.equal(unsignedTurn.status, 401);

    // Before the ban, the signed request is accepted (refused only for lack
    // of TURN_SECRET/TURN_URLS configuration in this test process, which is
    // still not 403 — proving 403 is specific to the ban, not the default).
    const beforeBan = await fetch(`${endpoint}/turn`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify(turnEvent),
    });
    assert.notEqual(beforeBan.status, 403);

    // Report and ban that npub through the real, wired-up flow: sign a
    // /report event carrying targetNpub, submit it, then ban it through the
    // real /admin/reports/<id>/ban route.
    const reportEvent = signed({
      tags: [['action', 'report']],
      content: JSON.stringify({
        reason: 'abuse', context: 'direct', target: 'bb'.repeat(32), targetNpub: bannedNpub,
      }),
    });
    const reportResponse = await fetch(`${endpoint}/report`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify(reportEvent),
    });
    assert.equal(reportResponse.status, 200);
    const { id } = await reportResponse.json();

    const banResponse = await fetch(`${endpoint}/admin/reports/${id}/ban`, {
      method: 'POST', headers: { authorization: 'Bearer test-admin-token' },
    });
    assert.equal(banResponse.status, 200);

    const turnAfter = await fetch(`${endpoint}/turn`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify(turnEvent),
    });
    assert.equal(turnAfter.status, 403);
    assert.equal((await turnAfter.json()).reason, 'banned');

    const registerEvent = signed({ tags: [], content: 'deadbeef'.repeat(8) });
    // Same key as turnEvent's pubkey only if it reuses key '02'.repeat(32);
    // signed() always uses that fixed key, so pubkey is the same npub.
    assert.equal(registerEvent.pubkey, bannedNpub);
    const registerAfter = await fetch(`${endpoint}/register`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify(registerEvent),
    });
    assert.equal(registerAfter.status, 403);
    assert.equal((await registerAfter.json()).reason, 'banned');
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('target, targetNpub and fingerprint hex are lower-cased before insertion', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cubechat-bans-case-'));
  const bans = createBans({ path: path.join(dir, 'banned.json'), signingKeyPkcs8B64: pkcs8B64, nowSeconds: now });
  const mixedTarget = 'AA'.repeat(32);
  const mixedNpub = 'BB'.repeat(32);
  await bans.ban(reportFixture({ target: mixedTarget, targetNpub: mixedNpub, context: 'direct' }));
  const body = bans.list();
  assert.ok(body.identities.includes(mixedTarget.toLowerCase()));
  assert.equal(body.identities.includes(mixedTarget), false);
  assert.ok(body.npubs.includes(mixedNpub.toLowerCase()));
  assert.equal(bans.isBannedNpub(mixedNpub.toLowerCase()), true);

  const dir2 = await mkdtemp(path.join(tmpdir(), 'cubechat-bans-case-'));
  const bans2 = createBans({ path: path.join(dir2, 'banned.json'), signingKeyPkcs8B64: pkcs8B64, nowSeconds: now });
  const mixedFingerprint = 'CC'.repeat(32);
  await bans2.ban(reportFixture({ context: 'channel', target: mixedFingerprint }));
  assert.ok(bans2.list().fingerprints.includes(mixedFingerprint.toLowerCase()));

  // unban matches regardless of the case it's asked for in.
  assert.equal(await bans.unban(mixedTarget), true);
  assert.equal(bans.list().identities.includes(mixedTarget.toLowerCase()), false);
});

test('with no signing key configured, list() carries no signature', () => {
  const dir = mkdtemp(path.join(tmpdir(), 'cubechat-bans-unconfigured-'));
  return dir.then((d) => {
    const bans = createBans({ path: path.join(d, 'banned.json'), signingKeyPkcs8B64: '', nowSeconds: now });
    assert.equal(bans.configured, false);
    assert.equal(bans.list().sig, '');
  });
});

// Review round 1, item 3: a *real* HTTP test for the 503 `unconfigured`
// case, not just a check of `bans.configured` — a plain node:http server
// wired to `handleBanned` with a `bans` instance built without a signing
// key, the same "inject the dependency" shape `handleAdmin`/`handleTurn`'s
// own tests already use (`fakeBans`, `bans` as an option), rather than the
// module's own singleton `adminBans`, which this test file's `BAN_SIGNING_KEY`
// env var always configures.
test('GET /banned is a real 503 unconfigured over HTTP when the injected bans has no signing key', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cubechat-bans-unconfigured-http-'));
  const unconfiguredBans = createBans({ path: path.join(dir, 'banned.json'), signingKeyPkcs8B64: '', nowSeconds: now });
  assert.equal(unconfiguredBans.configured, false);

  const testServer = createHttpServer((request, response) => {
    const result = handleBanned({ bans: unconfiguredBans });
    const text = JSON.stringify(result.body);
    response.writeHead(result.status, {
      'content-type': 'application/json',
      'cache-control': result.cacheControl,
    });
    response.end(text);
  });
  testServer.listen(0, '127.0.0.1');
  await once(testServer, 'listening');
  try {
    const endpoint = `http://127.0.0.1:${testServer.address().port}`;
    const response = await fetch(`${endpoint}/banned`);
    assert.equal(response.status, 503);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    const body = await response.json();
    assert.equal(body.reason, 'unconfigured');
  } finally {
    await new Promise((resolve) => testServer.close(resolve));
  }
});
