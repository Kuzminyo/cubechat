import assert from 'node:assert/strict';
import test from 'node:test';
import { cubesFor, ladder, MIN_CUBES, PRODUCTS } from '../src/products.js';

test('every bigger pack is strictly cheaper per cube', () => {
  // The rule that makes a volume discount a discount. Break it and some pack
  // costs more per cube than a smaller one — a trap, and one that appears
  // quietly the day a store's price grid moves a single row.
  const rungs = ladder();
  for (let i = 1; i < rungs.length; i++) {
    assert.ok(
      rungs[i].perCube < rungs[i - 1].perCube,
      `${rungs[i].id} at ${rungs[i].perCube.toFixed(5)}/cube is not cheaper ` +
        `than ${rungs[i - 1].id} at ${rungs[i - 1].perCube.toFixed(5)}`,
    );
  }
});

test('buying a bigger pack always beats repeating a smaller one', () => {
  // The other half of the same promise, and the one a buyer actually checks:
  // 200 must cost less than two hundreds.
  const rungs = ladder();
  for (const rung of rungs.slice(1)) {
    for (const smaller of rungs.filter((r) => r.cubes < rung.cubes)) {
      const repeats = Math.ceil(rung.cubes / smaller.cubes);
      assert.ok(
        rung.usd < repeats * smaller.usd,
        `${rung.id} costs ${rung.usd}, but ${repeats} x ${smaller.id} is ` +
          `${(repeats * smaller.usd).toFixed(2)}`,
      );
    }
  }
});

test('nothing is sold below the floor', () => {
  for (const [id, p] of Object.entries(PRODUCTS)) {
    assert.ok(p.cubes >= MIN_CUBES, `${id} is under the floor`);
  }
});

test('the amount comes from this table and nowhere else', () => {
  assert.equal(cubesFor('cubes.500'), 500);
  assert.equal(cubesFor('cubes.4242'), null);
  assert.equal(cubesFor(''), null);
  assert.equal(cubesFor(undefined), null);
});

test('the id says how many cubes it gives', () => {
  // A mismatch here would be invisible in the console and wrong in the
  // ledger — the buyer sees "500" on the button and gets whatever the table
  // says.
  for (const [id, p] of Object.entries(PRODUCTS)) {
    assert.equal(Number(id.split('.')[1]), p.cubes, `${id} disagrees`);
  }
});

test('the table cannot be edited at runtime', () => {
  assert.throws(() => {
    PRODUCTS['cubes.100'] = { cubes: 999999, usd: 0.01 };
  });
});
