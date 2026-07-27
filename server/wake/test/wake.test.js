import assert from 'node:assert/strict';
import { generateKeyPairSync, randomBytes, sign } from 'node:crypto';
import test from 'node:test';

import {
  CAP_DOMAIN,
  TICKET_DOMAIN,
  b64uEncode,
  lookupOf,
  registrationTranscript,
} from '../src/crypto.js';
import { WakeService } from '../src/service.js';
import { Store } from '../src/store.js';

/** Records what would have gone to Apple, and answers however a test wants. */
class FakeApns {
  constructor() {
    this.sent = [];
    this.status = 200;
  }

  async send(args) {
    this.sent.push(args);
    return { status: this.status, reason: '' };
  }
}

/** A control key pair, plus a signer for the registration transcript. */
function controlKey() {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const raw = publicKey.export({ format: 'jwk' });
  const pub = Buffer.from(raw.x, 'base64url');
  return {
    pub,
    signTranscript: (t) => sign(null, t, privateKey),
  };
}

function makeService({ now = () => 1_700_000_000_000, config = {} } = {}) {
  const store = new Store({ now });
  const apns = new FakeApns();
  const service = new WakeService({ store, apns, config, now });
  return { store, apns, service };
}

function register(service, key, overrides = {}) {
  const deviceToken = randomBytes(32);
  const nonce = randomBytes(16);
  const timestamp = Math.floor(1_700_000_000_000 / 1000);
  const fields = {
    controlPubkey: key.pub,
    deviceToken,
    environment: 'sandbox',
    topic: 'com.cubechat.cubechat',
    timestamp,
    nonce,
    ...overrides,
  };
  const signature = key.signTranscript(registrationTranscript(fields));
  return service.registerTicket({
    version: 1,
    control_pubkey: b64uEncode(fields.controlPubkey),
    device_token: b64uEncode(fields.deviceToken),
    environment: fields.environment,
    topic: fields.topic,
    timestamp: fields.timestamp,
    nonce: b64uEncode(fields.nonce),
    signature: b64uEncode(signature),
  });
}

/** Register a ticket and bind one capability to it. */
function registered(service, key) {
  const res = register(service, key);
  assert.equal(res.status, 200);
  const ticket = res.body.delivery_ticket;
  const capability = randomBytes(32);
  const cap = service.registerCapability({
    version: 1,
    cap_lookup: lookupOf(CAP_DOMAIN, capability),
    delivery_ticket: ticket,
    control_pubkey: b64uEncode(key.pub),
    expires_at: Math.floor(1_700_000_000_000 / 1000) + 86400,
  });
  assert.equal(cap.status, 200);
  return { ticket, capability };
}

test('a signed registration mints a ticket', () => {
  const { service } = makeService();
  const res = register(service, controlKey());
  assert.equal(res.status, 200);
  assert.ok(res.body.delivery_ticket);
  assert.ok(res.body.registration_id);
});

test('a registration signed by the wrong key is refused', () => {
  const { service } = makeService();
  const real = controlKey();
  const impostor = controlKey();
  const deviceToken = randomBytes(32);
  const nonce = randomBytes(16);
  const timestamp = Math.floor(1_700_000_000_000 / 1000);
  const transcript = registrationTranscript({
    controlPubkey: real.pub,
    deviceToken,
    environment: 'sandbox',
    topic: 'com.cubechat.cubechat',
    timestamp,
    nonce,
  });
  const res = service.registerTicket({
    version: 1,
    control_pubkey: b64uEncode(real.pub),
    device_token: b64uEncode(deviceToken),
    environment: 'sandbox',
    topic: 'com.cubechat.cubechat',
    timestamp,
    nonce: b64uEncode(nonce),
    signature: b64uEncode(impostor.signTranscript(transcript)),
  });
  assert.equal(res.status, 401);
});

test('a registration from far in the past is refused', () => {
  const { service } = makeService();
  const res = register(service, controlKey(), {
    timestamp: Math.floor(1_700_000_000_000 / 1000) - 3600,
  });
  assert.equal(res.status, 400);
});

test('the store never holds the bearer ticket, only its hash', () => {
  const { service, store } = makeService();
  const res = register(service, controlKey());
  const ticket = res.body.delivery_ticket;
  const serialised = JSON.stringify(Object.fromEntries(store._tickets));
  assert.ok(!serialised.includes(ticket), 'bearer ticket must not be stored');
  assert.ok(store.getTicket(lookupOf(TICKET_DOMAIN, Buffer.from(ticket, 'base64url'))));
});

test('a wake rings the device once', async () => {
  const { service, apns } = makeService();
  const { capability } = registered(service, controlKey());

  const res = await service.wake({ version: 1, capability: b64uEncode(capability) });
  assert.equal(res.status, 202);
  assert.equal(apns.sent.length, 1);
  assert.equal(apns.sent[0].topic, 'com.cubechat.cubechat');
});

test('the push carries no caller-supplied content', async () => {
  const { service, apns } = makeService();
  const { capability } = registered(service, controlKey());
  await service.wake({
    version: 1,
    capability: b64uEncode(capability),
    // A caller trying to smuggle text through.
    alert: 'transfer your coins to attacker.example',
    badge: 99,
  });
  assert.equal(apns.sent.length, 1);
  assert.deepEqual(Object.keys(apns.sent[0]).sort(), [
    'deviceToken',
    'environment',
    'template',
    'topic',
  ]);
  assert.equal(apns.sent[0].template, 'cubechat-wake-v1');
});

test('an unknown capability is indistinguishable from a delivered one', async () => {
  const { service, apns } = makeService();
  registered(service, controlKey());

  const res = await service.wake({
    version: 1,
    capability: b64uEncode(randomBytes(32)),
  });
  assert.equal(res.status, 202, 'must not become an existence oracle');
  assert.equal(apns.sent.length, 0);
});

test('a revoked capability answers exactly as a live one does', async () => {
  const { service, store, apns } = makeService();
  const key = controlKey();
  const { capability } = registered(service, key);
  store.revokeCapability(lookupOf(CAP_DOMAIN, capability));

  const res = await service.wake({ version: 1, capability: b64uEncode(capability) });
  assert.equal(res.status, 202);
  assert.equal(apns.sent.length, 0);
});

test('a burst is coalesced into one ring', async () => {
  let clock = 1_700_000_000_000;
  const { service, apns } = makeService({ now: () => clock });
  const { capability } = registered(service, controlKey());
  const body = { version: 1, capability: b64uEncode(capability) };

  await service.wake(body);
  clock += 200;
  await service.wake(body);
  clock += 200;
  await service.wake(body);
  assert.equal(apns.sent.length, 1, 'three contacts, one ring');

  clock += 5000;
  await service.wake(body);
  assert.equal(apns.sent.length, 2, 'a later message rings again');
});

test('a malicious contact is bounded by the per-capability limit', async () => {
  let clock = 1_700_000_000_000;
  const { service, apns } = makeService({
    now: () => clock,
    config: { coalesceMs: 0, wakePerMinute: 3 },
  });
  const { capability } = registered(service, controlKey());
  const body = { version: 1, capability: b64uEncode(capability) };

  for (let i = 0; i < 20; i++) {
    clock += 100;
    await service.wake(body);
  }
  assert.equal(apns.sent.length, 3, 'spam is capped, not amplified');
});

test('APNs 410 stops delivery to a dead token', async () => {
  const { service, apns, store } = makeService({ config: { coalesceMs: 0 } });
  const { capability } = registered(service, controlKey());
  const body = { version: 1, capability: b64uEncode(capability) };

  apns.status = 410;
  await service.wake(body);
  assert.equal(apns.sent.length, 1);

  apns.status = 200;
  await service.wake(body);
  assert.equal(apns.sent.length, 1, 'the disabled token is not retried');
  void store;
});

test('a capability cannot be bound to a ticket that does not exist', () => {
  const { service } = makeService();
  const key = controlKey();
  const res = service.registerCapability({
    version: 1,
    cap_lookup: lookupOf(CAP_DOMAIN, randomBytes(32)),
    delivery_ticket: b64uEncode(randomBytes(32)),
    control_pubkey: b64uEncode(key.pub),
    expires_at: Math.floor(1_700_000_000_000 / 1000) + 86400,
  });
  assert.equal(res.status, 404);
});

test('the frontend table never contains a device token', () => {
  const { service, store } = makeService();
  const key = controlKey();
  registered(service, key);
  const caps = JSON.stringify(Object.fromEntries(store._caps));
  for (const row of store._tickets.values()) {
    assert.ok(!caps.includes(row.deviceToken), 'a token must not cross the boundary');
  }
});

test('an expired capability is swept and stops ringing', async () => {
  let clock = 1_700_000_000_000;
  const { service, apns } = makeService({ now: () => clock });
  const { capability } = registered(service, controlKey());

  clock += 2 * 86400 * 1000; // past the one-day expiry the helper set
  const res = await service.wake({ version: 1, capability: b64uEncode(capability) });
  assert.equal(res.status, 202);
  assert.equal(apns.sent.length, 0);
});
