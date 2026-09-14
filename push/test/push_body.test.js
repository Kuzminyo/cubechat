import assert from 'node:assert/strict';
import test from 'node:test';
import { pushBody } from '../src/index.js';

// A call invite carries CALL_TAG beside WAKE_TAG. The doorbell for it has to
// say "call", in the registered language, and fall back like a message does.
test('a call is announced as a call, a message as a message', () => {
  assert.equal(pushBody('en'), 'New message');
  assert.equal(pushBody('en', { call: true }), 'Incoming call');
  assert.equal(pushBody('uk', { call: true }), 'Вхідний дзвінок');
});

test('an unknown or missing language falls back to English for both', () => {
  assert.equal(pushBody(undefined, { call: true }), 'Incoming call');
  assert.equal(pushBody('xx'), 'New message');
});
