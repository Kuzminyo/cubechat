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

// The PushKit token rides in a signed tag. Only an iPhone's is believed, and
// only a well-formed one: it is handed straight to Apple.
test('a VoIP token is read from an iOS registration and nowhere else', async () => {
  const { voipTokenOf } = await import('../src/index.js');
  const hex = 'ab'.repeat(32);
  assert.equal(voipTokenOf({ tags: [['voip', hex]] }, 'ios'), hex);
  assert.equal(voipTokenOf({ tags: [['voip', hex]] }, 'android'), null);
  assert.equal(voipTokenOf({ tags: [['voip', 'not hex']] }, 'ios'), null);
  assert.equal(voipTokenOf({ tags: [] }, 'ios'), null);
});
