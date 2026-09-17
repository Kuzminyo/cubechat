import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { openStore } from '../src/store.js';

const A = 'a'.repeat(64);
const B = 'b'.repeat(64);

const fresh = () => openStore(':memory:');

test('a credited balance is there after a reopen', () => {
  // The whole reason this is SQLite and not a Map: losing a row here is losing
  // somebody's money.
  const dir = mkdtempSync(join(tmpdir(), 'wallet-'));
  const file = join(dir, 'cubes.db');
  try {
    let store = openStore(file);
    store.credit({ npub: A, amount: 100, ref: 'tx1', source: 'apple' });
    store.close();

    store = openStore(file);
    assert.equal(store.balanceOf(A), 100);
    store.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the same store transaction credits exactly once', () => {
  // Mobile networks lose replies, so the app will send the same receipt again.
  const store = fresh();
  store.credit({ npub: A, amount: 100, ref: 'tx1', source: 'apple' });
  store.credit({ npub: A, amount: 100, ref: 'tx1', source: 'apple' });
  assert.equal(store.balanceOf(A), 100);
  store.close();
});

test('a failed transfer leaves both balances untouched', () => {
  const store = fresh();
  store.credit({ npub: A, amount: 10, ref: 'tx1', source: 'apple' });
  assert.throws(
    () => store.transfer({ from: A, to: B, amount: 50, ref: 't1' }),
    (e) => e.code === 'insufficient',
  );
  assert.equal(store.balanceOf(A), 10);
  assert.equal(store.balanceOf(B), 0);
  store.close();
});

test('a failed transfer writes no journal row either', () => {
  // A row for something that did not happen is worse than no row: it is what
  // a dispute is settled from.
  const store = fresh();
  store.credit({ npub: A, amount: 10, ref: 'tx1', source: 'apple' });
  try {
    store.transfer({ from: A, to: B, amount: 50, ref: 't1' });
  } catch {}
  assert.equal(store.journal(A, 10).length, 1);
  store.close();
});

test('a transfer is idempotent by its ref', () => {
  const store = fresh();
  store.credit({ npub: A, amount: 10, ref: 'tx1', source: 'apple' });
  store.transfer({ from: A, to: B, amount: 4, ref: 't1' });
  store.transfer({ from: A, to: B, amount: 4, ref: 't1' });
  assert.equal(store.balanceOf(A), 6);
  assert.equal(store.balanceOf(B), 4);
  store.close();
});

test('a transfer moves value and creates none', () => {
  const store = fresh();
  store.credit({ npub: A, amount: 100, ref: 'tx1', source: 'apple' });
  store.transfer({ from: A, to: B, amount: 30, ref: 't1' });
  assert.equal(store.balanceOf(A) + store.balanceOf(B), 100);
  store.close();
});

test('an unknown account has a balance of zero, not an error', () => {
  const store = fresh();
  assert.equal(store.balanceOf(B), 0);
  store.close();
});

test('a refund takes the balance below zero and blocks spending', () => {
  const store = fresh();
  store.credit({ npub: A, amount: 20, ref: 'tx1', source: 'apple' });
  store.refund({ npub: A, amount: 100, ref: 'tx1' });
  assert.equal(store.balanceOf(A), -80);
  assert.throws(
    () => store.transfer({ from: A, to: B, amount: 1, ref: 't1' }),
    (e) => e.code === 'insufficient',
  );
  store.close();
});

test('the journal records what happened, newest first', () => {
  const store = fresh();
  store.credit({ npub: A, amount: 10, ref: 'tx1', source: 'apple' });
  store.transfer({ from: A, to: B, amount: 4, ref: 't1' });

  const rows = store.journal(A, 10);
  assert.equal(rows.length, 2);
  assert.equal(rows[0].kind, 'transfer');
  assert.equal(rows[0].amount, 4);
  assert.equal(rows[0].to_npub, B);
  assert.equal(rows[1].kind, 'credit');
  store.close();
});

test("a transfer shows up in the recipient's journal too", () => {
  const store = fresh();
  store.credit({ npub: A, amount: 10, ref: 'tx1', source: 'apple' });
  store.transfer({ from: A, to: B, amount: 4, ref: 't1' });
  assert.equal(store.journal(B, 10).length, 1);
  store.close();
});

test('the ledger rules are not re-implemented in SQL', () => {
  // Amount and npub checks live in ledger.js; the store must go through them
  // rather than growing a second, drifting copy.
  const store = fresh();
  assert.throws(
    () => store.credit({ npub: A, amount: 1.5, ref: 'x', source: 'apple' }),
    (e) => e.code === 'amount',
  );
  assert.throws(
    () => store.credit({ npub: 'nope', amount: 1, ref: 'x', source: 'apple' }),
    (e) => e.code === 'npub',
  );
  store.close();
});
