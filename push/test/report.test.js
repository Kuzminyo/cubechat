import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { once } from 'node:events';
import path from 'node:path';
import test from 'node:test';
import { schnorr } from '@noble/curves/secp256k1';

// The store this file's server test hits must not be the one every other
// test file shares — reports.jsonl would otherwise accumulate rows across
// runs and the `since`/limiter assertions would see stale state. Node's test
// runner puts each file in its own process, so setting this before the
// dynamic import below is enough to steer this file's copy of the module.
const reportsDir = await mkdtemp(path.join(tmpdir(), 'cubechat-reports-'));
process.env.REPORTS_PATH = path.join(reportsDir, 'reports.jsonl');

const { handleReport, createRateLimiter, createReportStore, server } =
  await import('../src/index.js');

const now = 1789000000;
const REPORT_KEY = '03'.repeat(32);

function signed({ tags = [['action', 'report']], createdAt = now, content, key = REPORT_KEY, kind = 24242 } = {}) {
  const body = content !== undefined ? content : JSON.stringify(validPayload());
  const event = { pubkey: Buffer.from(schnorr.getPublicKey(key)).toString('hex'),
    created_at: createdAt, kind, tags, content: body };
  event.id = createHash('sha256').update(JSON.stringify([
    0, event.pubkey, event.created_at, event.kind, event.tags, event.content,
  ])).digest('hex');
  event.sig = Buffer.from(schnorr.sign(event.id, key)).toString('hex');
  return event;
}

function validPayload(overrides = {}) {
  return {
    reason: 'spam',
    context: 'direct',
    target: 'ab'.repeat(32),
    ...overrides,
  };
}

// A store fake, so tests of `handleReport` itself never touch the filesystem
// — only the HTTP route test (7) does, through the real store.
function fakeStore() {
  const appended = [];
  let seq = 1;
  return {
    calls: appended,
    async append(report) {
      const stored = { ...report, seq: seq++ };
      appended.push(stored);
      return stored;
    },
  };
}

function fakeLimiter(allow = true) {
  const calls = [];
  return { calls, allow(pubkey, nowSeconds) { calls.push([pubkey, nowSeconds]); return allow; } };
}

test('a valid report is stored open, under the reporter\'s key, and notified once', async () => {
  const store = fakeStore();
  const notifyCalls = [];
  const event = signed();
  const result = await handleReport(event, {
    nowSeconds: now, limiter: fakeLimiter(), store, notify: (r) => notifyCalls.push(r),
  });
  assert.equal(result.status, 200);
  assert.equal(result.body.ok, true);
  assert.equal(typeof result.body.id, 'string');
  assert.equal(store.calls.length, 1);
  assert.equal(store.calls[0].status, 'open');
  assert.equal(store.calls[0].reporter, event.pubkey);
  assert.equal(store.calls[0].id, result.body.id);
  assert.equal(notifyCalls.length, 1);
});

test('a bad signature, wrong kind, missing tag or a /turn-tagged event are all refused the same way', async () => {
  const store = fakeStore();
  const cases = [
    null,
    {},
    signed({ tags: [] }),
    signed({ tags: [['action', 'turn']] }),
    { ...signed(), content: 'tampered but still json {}' },
    signed({ kind: 1 }), // a correctly signed event of the wrong kind
  ];
  for (const event of cases) {
    const result = await handleReport(event, { nowSeconds: now, limiter: fakeLimiter(), store });
    assert.equal(result.status, 401);
    assert.equal(result.body.reason, 'signature');
  }
  assert.equal(store.calls.length, 0);
});

test('a report signed too long ago or too far in the future is refused as stale', async () => {
  const store = fakeStore();
  for (const createdAt of [now - 601, now + 61]) {
    const result = await handleReport(signed({ createdAt }), {
      nowSeconds: now, limiter: fakeLimiter(), store,
    });
    assert.equal(result.status, 401);
    assert.equal(result.body.reason, 'stale');
  }
  // The edges themselves are still accepted.
  for (const createdAt of [now - 600, now + 60]) {
    const result = await handleReport(signed({ createdAt }), {
      nowSeconds: now, limiter: fakeLimiter(), store,
    });
    assert.equal(result.status, 200);
  }
});

test('malformed or out-of-range report content is refused as a bad payload', async () => {
  const store = fakeStore();
  const contents = [
    'not json at all',
    JSON.stringify(validPayload({ reason: 'not-a-reason' })),
    JSON.stringify(validPayload({ context: 'not-a-context' })),
    JSON.stringify(validPayload({ note: 'x'.repeat(501) })),
    JSON.stringify(validPayload({ message: { text: 'x'.repeat(4001) } })),
    JSON.stringify(validPayload({ target: 'not-64-hex' })),
    JSON.stringify({ reason: 'spam', context: 'direct' }), // direct without target
  ];
  for (const content of contents) {
    const result = await handleReport(signed({ content }), {
      nowSeconds: now, limiter: fakeLimiter(), store,
    });
    assert.equal(result.status, 400, content);
    assert.equal(result.body.reason, 'payload');
  }
  assert.equal(store.calls.length, 0);
});

test('message.sentAt must be a non-negative safe integer', async () => {
  const store = fakeStore();
  for (const sentAt of [-1, 1.5, NaN, Infinity, -Infinity, Number.MAX_SAFE_INTEGER + 1]) {
    const content = JSON.stringify(validPayload({ message: { text: 'hi', sentAt } }));
    const result = await handleReport(signed({ content }), {
      nowSeconds: now, limiter: fakeLimiter(), store,
    });
    assert.equal(result.status, 400, `sentAt ${sentAt} should be refused`);
    assert.equal(result.body.reason, 'payload');
  }
  // 0 and an ordinary timestamp are both fine.
  for (const sentAt of [0, now]) {
    const content = JSON.stringify(validPayload({ message: { text: 'hi', sentAt } }));
    const result = await handleReport(signed({ content }), {
      nowSeconds: now, limiter: fakeLimiter(), store,
    });
    assert.equal(result.status, 200, `sentAt ${sentAt} should be accepted`);
  }
});

test('a channel author can be reported by the 16-hex signing fingerprint available to receivers', async () => {
  const store = fakeStore();
  const content = JSON.stringify({ reason: 'abuse', context: 'channel', channelId: '#room', target: 'ab'.repeat(8) });
  const result = await handleReport(signed({ content }), {
    nowSeconds: now, limiter: fakeLimiter(), store,
  });
  assert.equal(result.status, 200);
  assert.equal(store.calls[0].target, 'ab'.repeat(8));
});

test('a general report needs no target', async () => {
  const store = fakeStore();
  const content = JSON.stringify({ reason: 'other', context: 'general' });
  const result = await handleReport(signed({ content }), {
    nowSeconds: now, limiter: fakeLimiter(), store,
  });
  assert.equal(result.status, 200);
  assert.equal(store.calls[0].context, 'general');
  assert.equal(store.calls[0].target, undefined);
});

test('the note and message caps, and a 500-char note, are all accepted at the edge', async () => {
  const store = fakeStore();
  const content = JSON.stringify(validPayload({
    note: 'n'.repeat(500), message: { text: 't'.repeat(4000), kind: 'text', sentAt: now },
  }));
  const result = await handleReport(signed({ content }), {
    nowSeconds: now, limiter: fakeLimiter(), store,
  });
  assert.equal(result.status, 200);
  assert.equal(store.calls[0].note.length, 500);
  assert.equal(store.calls[0].message.text.length, 4000);
});

test('the rate limiter caps one key at 10 an hour and the whole service at 200, and both free up after an hour', () => {
  const perKeyLimiter = createRateLimiter({ perKey: 10, total: 200, windowSeconds: 3600 });
  const key = 'a'.repeat(64);
  for (let i = 0; i < 10; i++) assert.equal(perKeyLimiter.allow(key, now + i), true);
  assert.equal(perKeyLimiter.allow(key, now + 10), false, '11th from the same key is refused');
  assert.equal(perKeyLimiter.allow(key, now + 3600 + 100), true, 'the key\'s quota frees after an hour');

  const totalLimiter = createRateLimiter({ perKey: 1000, total: 200, windowSeconds: 3600 });
  for (let i = 0; i < 200; i++) assert.equal(totalLimiter.allow(`key-${i}`, now + i), true);
  assert.equal(totalLimiter.allow('key-200', now + 200), false, '201st overall is refused');
  assert.equal(totalLimiter.allow('key-200', now + 3600 + 100), true, 'the total quota frees after an hour');
});

test('the rate limiter does not grow without bound as keys rotate', () => {
  // /report has no identity beyond the signing key on the event, so a caller
  // that signs with a fresh key every time must not be able to grow the
  // limiter's memory forever just by rotating keys.
  const limiter = createRateLimiter({ perKey: 10, total: 1_000_000, windowSeconds: 3600, sweepEvery: 1 });
  for (let i = 0; i < 5000; i++) {
    limiter.allow(`key-${i}`, now + i);
  }
  assert.ok(limiter.size > 1, 'entries still inside the window are legitimately kept');

  // Advance well past every entry's window and make one more call: a sweep
  // (sweepEvery: 1, so every call sweeps) must have dropped everything whose
  // window has fully expired, leaving only the just-added key.
  limiter.allow('final-key', now + 5000 + 3600 + 10);
  assert.equal(limiter.size, 1, `expected only the newest key to remain, size=${limiter.size}`);
});

test('a notify that throws, or returns a rejected promise, still gives 200 and the report is stored', async () => {
  const throwingStore = fakeStore();
  const throwingResult = await handleReport(signed(), {
    nowSeconds: now, limiter: fakeLimiter(), store: throwingStore,
    notify: () => { throw new Error('telegram is down'); },
  });
  assert.equal(throwingResult.status, 200);
  assert.equal(throwingStore.calls.length, 1);

  const rejectingStore = fakeStore();
  const rejectingResult = await handleReport(signed(), {
    nowSeconds: now, limiter: fakeLimiter(), store: rejectingStore,
    notify: () => Promise.reject(new Error('telegram timed out')),
  });
  assert.equal(rejectingResult.status, 200);
  assert.equal(rejectingStore.calls.length, 1);
  // Let the rejected promise's .catch() run before the test process exits,
  // so it can't surface as an unhandled rejection in a later test.
  await new Promise((resolve) => setImmediate(resolve));
});

test('handleReport refuses the 11th report from one key within the hour with 429', async () => {
  const store = fakeStore();
  const limiter = createRateLimiter({ perKey: 10, total: 200, windowSeconds: 3600 });
  let last;
  for (let i = 0; i < 11; i++) {
    last = await handleReport(signed({ createdAt: now }), { nowSeconds: now, limiter, store });
  }
  assert.equal(last.status, 429);
  assert.equal(store.calls.length, 10);
});

test('the HTTP route stores a report through the real, file-backed store', async () => {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  try {
    const endpoint = `http://127.0.0.1:${server.address().port}`;
    const realNow = Math.floor(Date.now() / 1000);
    const response = await fetch(`${endpoint}/report`, { method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(signed({ key: randomBytes(32).toString('hex'), createdAt: realNow })) });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    const body = await response.json();
    assert.equal(body.ok, true);

    const bad = await fetch(`${endpoint}/report`, { method: 'POST',
      headers: { 'content-type': 'application/json' }, body: '{}' });
    assert.equal(bad.status, 401);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('createReportStore appends, updates through a rewrite, and lists open reports, all persisted', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cubechat-store-'));
  const file = path.join(dir, 'reports.jsonl');
  try {
    const store = createReportStore(file);
    const first = await store.append({ id: 'aaaa', status: 'open', reason: 'spam' });
    const second = await store.append({ id: 'bbbb', status: 'open', reason: 'abuse' });
    assert.equal(first.seq, 1);
    assert.equal(second.seq, 2);

    const decided = await store.update('aaaa', { status: 'banned' });
    assert.equal(decided.status, 'banned');

    const open = await store.open();
    assert.deepEqual(open.map((r) => r.id), ['bbbb']);

    // Reopen against the same file: seq must not reset or collide.
    const reopened = createReportStore(file);
    const third = await reopened.append({ id: 'cccc', status: 'open', reason: 'other' });
    assert.equal(third.seq, 3);
    const stillDecided = (await reopened.open()).find((r) => r.id === 'aaaa');
    assert.equal(stillDecided, undefined);

    const since = await reopened.since(1);
    assert.deepEqual(since.reports.map((r) => r.id).sort(), ['bbbb', 'cccc'].sort());
    assert.equal(since.next, 3);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

const DAY = 24 * 60 * 60;

test('purge drops a decided report past 90 days, keeps one at 89, and never touches an open one', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cubechat-purge-'));
  const file = path.join(dir, 'reports.jsonl');
  try {
    const store = createReportStore(file);
    await store.append({ id: 'gone', status: 'open', reason: 'spam' });
    await store.append({ id: 'kept-recent', status: 'open', reason: 'abuse' });
    await store.append({ id: 'kept-open', status: 'open', reason: 'other' });
    await store.decide('gone', { status: 'dismissed', decidedAt: now - 91 * DAY });
    await store.decide('kept-recent', { status: 'dismissed', decidedAt: now - 89 * DAY });
    // Still open after 200 days: never purged, decided or not.
    // (decidedAt stays absent — it was never decided.)

    const removed = await store.purge(now);
    assert.equal(removed, 1);

    const ids = new Set((await store.since(0)).reports.map((r) => r.id));
    assert.equal(ids.has('gone'), false);
    assert.equal(ids.has('kept-recent'), true);
    assert.equal(ids.has('kept-open'), true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('purge preserves seq of survivors, does not reset the counter, and since() paging still works', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cubechat-purge-seq-'));
  const file = path.join(dir, 'reports.jsonl');
  try {
    const store = createReportStore(file);
    const first = await store.append({ id: 'a', status: 'open' });
    const second = await store.append({ id: 'b', status: 'open' });
    await store.decide('a', { status: 'dismissed', decidedAt: now - 91 * DAY });
    assert.equal(first.seq, 1);
    assert.equal(second.seq, 2);

    const removed = await store.purge(now);
    assert.equal(removed, 1);

    // 'b' kept its seq of 2 — the purge only drops rows, it never renumbers.
    const survivor = await store.get('b');
    assert.equal(survivor.seq, 2);

    // The in-memory counter carries on from where it was, not from the
    // (now lower) max seq still on disk.
    const third = await store.append({ id: 'c', status: 'open' });
    assert.equal(third.seq, 3);

    const since = await store.since(0);
    assert.deepEqual(since.reports.map((r) => r.id), ['b', 'c']);
    assert.equal(since.next, 3);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('a purge racing a decide does not lose the decision', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cubechat-purge-race-'));
  const file = path.join(dir, 'reports.jsonl');
  try {
    const store = createReportStore(file);
    await store.append({ id: 'r1', status: 'open', reason: 'spam' });

    // Both go through the same write queue; whichever runs first, the
    // decision must land — a purge can only ever remove reports that were
    // already decided long ago, and this one becomes decided *during* the
    // race, so it must never be the purge that wins the report away.
    const [decided] = await Promise.all([
      store.decide('r1', { status: 'dismissed', decidedAt: now }),
      store.purge(now),
    ]);

    assert.ok(decided.report, 'the decision must have gone through');
    assert.equal(decided.report.status, 'dismissed');
    const stored = await store.get('r1');
    assert.equal(stored.status, 'dismissed');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
