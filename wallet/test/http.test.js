import assert from 'node:assert/strict';
import { once } from 'node:events';
import test from 'node:test';
import { schnorr } from '@noble/curves/secp256k1';
import { sha256 } from '@noble/hashes/sha256';
import { bytesToHex, utf8ToBytes } from '@noble/hashes/utils';

process.env.CUBECHAT_WALLET_DB = ':memory:';
const { server, store } = await import('../src/index.js');

const PAYER_KEY = '02'.repeat(32);
const THIEF_KEY = '03'.repeat(32);
const PAYER = bytesToHex(schnorr.getPublicKey(PAYER_KEY));
const THIEF = bytesToHex(schnorr.getPublicKey(THIEF_KEY));
const PAYEE = 'c'.repeat(64);
const VICTIM = 'd'.repeat(64);

function signed({ key = PAYER_KEY, tags = [] }) {
  const event = {
    pubkey: bytesToHex(schnorr.getPublicKey(key)),
    created_at: Math.floor(Date.now() / 1000),
    kind: 24242,
    tags,
    content: '',
  };
  event.id = bytesToHex(
    sha256(
      utf8ToBytes(
        JSON.stringify([
          0,
          event.pubkey,
          event.created_at,
          event.kind,
          event.tags,
          event.content,
        ]),
      ),
    ),
  );
  event.sig = bytesToHex(schnorr.sign(event.id, key));
  return event;
}

async function post(path, body) {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  try {
    const response = await fetch(
      `http://127.0.0.1:${server.address().port}${path}`,
      {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      },
    );
    return { status: response.status, body: await response.json() };
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

test('an unsigned request is refused', async () => {
  // Without this the wallet is an oracle for "how much does this npub have",
  // answerable by anybody who knows a public key.
  const { status } = await post('/balance', { npub: PAYER });
  assert.equal(status, 401);
});

test('a signed request gets its own balance', async () => {
  const { status, body } = await post('/balance', {
    event: signed({ tags: [['op', 'balance']] }),
  });
  assert.equal(status, 200);
  assert.equal(body.cubes, 0);
});

test('a transfer moves cubes between two keys', async () => {
  store.credit({ npub: PAYER, amount: 10, ref: 'tx1', source: 'apple' });

  const { status } = await post('/transfer', {
    event: signed({
      tags: [['op', 'transfer'], ['to', PAYEE], ['amount', '4'], ['id', 't1']],
    }),
  });

  assert.equal(status, 200);
  assert.equal(store.balanceOf(PAYER), 6);
  assert.equal(store.balanceOf(PAYEE), 4);
});

test('a transfer naming somebody else as the payer takes nothing', async () => {
  // The signature says who is spending. Reading the payer from a tag instead
  // would make this endpoint a way to empty any balance whose owner is known.
  store.credit({ npub: VICTIM, amount: 100, ref: 'tx2', source: 'apple' });

  const { status } = await post('/transfer', {
    event: signed({
      key: THIEF_KEY,
      tags: [
        ['op', 'transfer'],
        ['from', VICTIM],
        ['to', THIEF],
        ['amount', '50'],
        ['id', 't2'],
      ],
    }),
  });

  assert.equal(status, 400);
  assert.equal(store.balanceOf(VICTIM), 100);
  assert.equal(store.balanceOf(THIEF), 0);
});

test('a transfer beyond the balance is refused with a reason', async () => {
  const { status, body } = await post('/transfer', {
    event: signed({
      tags: [
        ['op', 'transfer'],
        ['to', PAYEE],
        ['amount', '9999'],
        ['id', 't3'],
      ],
    }),
  });
  assert.equal(status, 400);
  assert.equal(body.error, 'insufficient');
});

test('an amount that is not a whole number is refused', async () => {
  // '' becomes 0 and '1e3' becomes 1000 if a Number() is trusted.
  for (const [i, amount] of ['', '1.5', '1e3', '-4', ' 4'].entries()) {
    const { status } = await post('/transfer', {
      event: signed({
        tags: [
          ['op', 'transfer'],
          ['to', PAYEE],
          ['amount', amount],
          ['id', `bad${i}`],
        ],
      }),
    });
    assert.equal(status, 400, `accepted ${JSON.stringify(amount)}`);
  }
});

test('a transfer with no id is refused', async () => {
  // Without one a lost reply becomes a second payment on the retry.
  const { status, body } = await post('/transfer', {
    event: signed({
      tags: [['op', 'transfer'], ['to', PAYEE], ['amount', '1']],
    }),
  });
  assert.equal(status, 400);
  assert.equal(body.error, 'ref');
});

test('an unknown operation is not an error the caller can learn from',
  async () => {
    const { status } = await post('/nothing', {
      event: signed({ tags: [['op', 'nothing']] }),
    });
    assert.equal(status, 404);
  });
