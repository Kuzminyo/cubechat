import assert from 'node:assert/strict';
import test from 'node:test';
import {
  applyCredit,
  applyDebit,
  applyRefund,
  applyTransfer,
  LedgerError,
} from '../src/ledger.js';

const A = 'a'.repeat(64);
const B = 'b'.repeat(64);

const sum = (m) => [...m.values()].reduce((a, b) => a + b, 0);

test('a credit adds to an account that did not exist', () => {
  const after = applyCredit(new Map(), { npub: A, amount: 100 });
  assert.equal(after.get(A), 100);
});

test('a transfer moves value and creates none', () => {
  // The invariant the whole service exists to keep: the sum before equals the
  // sum after. A bug that breaks it prints money.
  const before = new Map([[A, 100], [B, 5]]);
  const after = applyTransfer(before, { from: A, to: B, amount: 30 });
  assert.equal(sum(after), sum(before));
  assert.equal(after.get(A), 70);
  assert.equal(after.get(B), 35);
});

test('the input is not mutated', () => {
  const before = new Map([[A, 100]]);
  applyTransfer(before, { from: A, to: B, amount: 30 });
  assert.equal(before.get(A), 100);
  assert.equal(before.has(B), false);
});

test('a transfer beyond the balance is refused, not overdrawn', () => {
  const before = new Map([[A, 10]]);
  assert.throws(
    () => applyTransfer(before, { from: A, to: B, amount: 11 }),
    (e) => e instanceof LedgerError && e.code === 'insufficient',
  );
});

test('a refund may push the balance below zero', () => {
  // The store took the money back after the cubes were spent. The balance owes
  // us; what was already bought with them stays bought.
  const after = applyRefund(new Map([[A, 20]]), { npub: A, amount: 100 });
  assert.equal(after.get(A), -80);
});

test('a negative balance cannot be spent from', () => {
  assert.throws(
    () => applyDebit(new Map([[A, -5]]), { npub: A, amount: 1 }),
    (e) => e.code === 'insufficient',
  );
});

test('amounts must be positive whole cubes', () => {
  for (const amount of [0, -1, 1.5, NaN, '10', null, undefined]) {
    assert.throws(
      () => applyCredit(new Map(), { npub: A, amount }),
      (e) => e.code === 'amount',
      `accepted ${amount}`,
    );
  }
});

test('an npub that is not 64 hex characters is refused', () => {
  // Anything else is a typo or an attempt, and either way it would open an
  // account nobody can ever sign for.
  for (const npub of ['', 'zz', A.toUpperCase(), `${A}0`, null]) {
    assert.throws(
      () => applyCredit(new Map(), { npub, amount: 1 }),
      (e) => e.code === 'npub',
      `accepted ${npub}`,
    );
  }
});

test('a transfer to yourself is refused', () => {
  // Otherwise it is a no-op that still writes a journal row and still costs
  // whatever a transfer costs.
  assert.throws(
    () => applyTransfer(new Map([[A, 10]]), { from: A, to: A, amount: 1 }),
    (e) => e.code === 'self',
  );
});

test('a transfer of the whole balance leaves zero, not a hole', () => {
  const after = applyTransfer(new Map([[A, 10]]), { from: A, to: B, amount: 10 });
  assert.equal(after.get(A), 0);
  assert.equal(after.get(B), 10);
  assert.equal(sum(after), 10);
});
