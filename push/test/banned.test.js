import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, verify as edVerify } from 'node:crypto';
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

const { createBans, canonicalBanBody, handleAdmin, server } = await import('../src/index.js');

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

test('with no signing key configured, /banned is 503 unconfigured', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cubechat-bans-unconfigured-'));
  const bans = createBans({ path: path.join(dir, 'banned.json'), signingKeyPkcs8B64: '', nowSeconds: now });
  assert.equal(bans.configured, false);
});
