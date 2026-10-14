import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { decide } from './write-policy.mjs';

const limits = { eventsPerMinute: 3, bytesPerHour: 10_000, minFreeBytes: 1000 };
const frame = (id, content = 'x') => ({ id, kind: 1059, content, tags: [['p', 'a'.repeat(64)]] });
const req = (event, ip = '203.0.113.1', sourceType = 'IP4') =>
  ({ type: 'new', event, receivedAt: 0, sourceType, sourceInfo: ip });
const run = (request, state, at = 0, freeBytes = 1e12) =>
  decide(request, state, { now: at, freeBytes, limits });

test('only cubechat frames are stored', () => {
  const state = new Map();
  assert.equal(run(req(frame('a')), state).action, 'accept');
  const note = run(req({ id: 'b', kind: 1, content: 'spam', tags: [] }), state);
  assert.equal(note.action, 'reject');
  assert.equal(note.id, 'b');
});

test('one address is held to its events a minute, others are not', () => {
  const state = new Map();
  for (const id of ['1', '2', '3']) assert.equal(run(req(frame(id)), state).action, 'accept');
  assert.equal(run(req(frame('4')), state).action, 'reject');
  assert.equal(run(req(frame('5'), '198.51.100.2'), state).action, 'accept');
  // A minute later the address may send again.
  assert.equal(run(req(frame('6')), state, 60_000).action, 'accept');
});

test('bytes an hour bound a run of large events', () => {
  const state = new Map();
  const big = 'y'.repeat(6000);
  assert.equal(run(req(frame('a', big)), state).action, 'accept');
  assert.equal(run(req(frame('b', big)), state, 61_000).action, 'reject');
  assert.equal(run(req(frame('c', big)), state, 3_600_000).action, 'accept');
});

test('a disk below the floor refuses every write', () => {
  assert.equal(run(req(frame('a')), new Map(), 0, 999).action, 'reject');
});

test("the operator's own imports and syncs are not limited", () => {
  const state = new Map();
  for (let i = 0; i < 10; i++) {
    assert.equal(run(req({ id: `${i}`, kind: 1, tags: [] }, '', 'Import'), state).action, 'accept');
  }
});

test('speaks strfry\'s line protocol', async () => {
  const child = spawn(process.execPath, [fileURLToPath(new URL('./write-policy.mjs', import.meta.url))]);
  child.stdin.write(`${JSON.stringify(req(frame('ok')))}\n`);
  child.stdin.write(`${JSON.stringify(req({ id: 'no', kind: 7, tags: [] }))}\n`);
  child.stdin.end();
  let out = '';
  child.stdout.on('data', (chunk) => { out += chunk; });
  await once(child, 'close');
  const answers = out.trim().split('\n').map((line) => JSON.parse(line));
  assert.deepEqual(answers.map((a) => [a.id, a.action]), [['ok', 'accept'], ['no', 'reject']]);
});
