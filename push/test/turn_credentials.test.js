import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import test from 'node:test';

import { turnCredentials } from '../src/index.js';

test('a TURN username is the moment the credential expires', () => {
  const credential = turnCredentials({
    secret: 'test-secret',
    ttlSeconds: 600,
    nowSeconds: 1789000000,
  });

  assert.equal(credential.username, '1789000600');
  assert.equal(credential.ttl, 600);
});

test('a TURN password authenticates the expiry under the shared secret', () => {
  const credential = turnCredentials({
    secret: 'test-secret',
    ttlSeconds: 600,
    nowSeconds: 1789000000,
  });
  const expected = createHmac('sha1', 'test-secret')
    .update(credential.username)
    .digest('base64');

  assert.equal(credential.password, expected);
});

test('a missing TURN secret is refused', () => {
  assert.throws(() =>
    turnCredentials({ secret: '', ttlSeconds: 600, nowSeconds: 1789000000 }),
  );
});
