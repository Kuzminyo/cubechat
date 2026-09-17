import assert from 'node:assert/strict';
import test from 'node:test';
import { verifyPurchase } from '../src/receipts.js';

/// Every test here is a way to get cubes for nothing. That is the whole job of
/// this module: the phone says what it bought, and only the store is believed.

function deps({ apple, google, throws = false } = {}) {
  return {
    async appleTransaction(token) {
      if (throws) throw new Error('network');
      return apple ?? null;
    },
    async googlePurchase({ productId, token }) {
      if (throws) throw new Error('network');
      return google ?? null;
    },
  };
}

test('a purchase the store confirms is credited', async () => {
  const out = await verifyPurchase(
    { platform: 'apple', token: 'tk', productId: 'cubes.500' },
    deps({ apple: { transactionId: 'a-1', productId: 'cubes.500', revoked: false } }),
  );
  assert.deepEqual(out, { ref: 'apple:a-1', cubes: 500 });
});

test('a purchase the store does not confirm credits nothing', async () => {
  const out = await verifyPurchase(
    { platform: 'apple', token: 'tk', productId: 'cubes.500' },
    deps({ apple: null }),
  );
  assert.equal(out, null);
});

test('a product we do not sell credits nothing, however loudly confirmed',
  async () => {
    const out = await verifyPurchase(
      { platform: 'apple', token: 'tk', productId: 'cubes.999999' },
      deps({
        apple: { transactionId: 'a-2', productId: 'cubes.999999', revoked: false },
      }),
    );
    assert.equal(out, null);
  });

test('the amount comes from our catalogue, not from the request', async () => {
  // The obvious attack: ask for 100, be credited what you claimed instead.
  const out = await verifyPurchase(
    { platform: 'apple', token: 'tk', productId: 'cubes.100', cubes: 1000000 },
    deps({ apple: { transactionId: 'a-3', productId: 'cubes.100', revoked: false } }),
  );
  assert.equal(out.cubes, 100);
});

test('the product the store names wins over the one the phone names',
  async () => {
    // Otherwise a receipt for the cheapest pack is presented as the dearest.
    const out = await verifyPurchase(
      { platform: 'apple', token: 'tk', productId: 'cubes.5000' },
      deps({
        apple: { transactionId: 'a-4', productId: 'cubes.100', revoked: false },
      }),
    );
    assert.equal(out, null);
  });

test('the reference comes from the store, not the caller', async () => {
  // A caller choosing its own reference could present one receipt under a
  // fresh id every time and be credited for each.
  const out = await verifyPurchase(
    { platform: 'apple', token: 'tk', productId: 'cubes.100', ref: 'mine' },
    deps({ apple: { transactionId: 'a-5', productId: 'cubes.100', revoked: false } }),
  );
  assert.equal(out.ref, 'apple:a-5');
});

test('a revoked purchase credits nothing', async () => {
  const out = await verifyPurchase(
    { platform: 'apple', token: 'tk', productId: 'cubes.100' },
    deps({ apple: { transactionId: 'a-6', productId: 'cubes.100', revoked: true } }),
  );
  assert.equal(out, null);
});

test('a network failure is a refusal, never a credit', async () => {
  // The dangerous default: "we could not reach Apple, so let them through".
  const out = await verifyPurchase(
    { platform: 'apple', token: 'tk', productId: 'cubes.100' },
    deps({ throws: true }),
  );
  assert.equal(out, null);
});

test('google is checked on its own terms', async () => {
  const out = await verifyPurchase(
    { platform: 'google', token: 'tk', productId: 'cubes.300' },
    deps({ google: { orderId: 'g-1', purchaseState: 0, acknowledged: false } }),
  );
  assert.deepEqual(out, { ref: 'google:g-1', cubes: 300 });
});

test('a google purchase that is pending or cancelled credits nothing',
  async () => {
    // 0 is purchased; 1 is cancelled and 2 is pending, and neither is money.
    for (const purchaseState of [1, 2]) {
      const out = await verifyPurchase(
        { platform: 'google', token: 'tk', productId: 'cubes.300' },
        deps({ google: { orderId: 'g-2', purchaseState } }),
      );
      assert.equal(out, null, `credited on state ${purchaseState}`);
    }
  });

test('a platform we do not know credits nothing', async () => {
  const out = await verifyPurchase(
    { platform: 'web', token: 'tk', productId: 'cubes.100' },
    deps({ apple: { transactionId: 'x', productId: 'cubes.100' } }),
  );
  assert.equal(out, null);
});
