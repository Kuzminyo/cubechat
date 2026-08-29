// The doorbell.
//
// Three moving parts and no more: a registry of npub -> APNs token, a
// subscription to the relays the app already uses, and one HTTP/2 call to Apple
// per event that lands for somebody we hold a token for.
//
// Everything it knows is in `tokens.json`. Everything it says is the same
// fixed string. It has never seen a key and cannot decrypt anything, which is
// not a policy but a fact about what it is given.

import { createServer } from 'node:http';
import { readFile, writeFile, rename } from 'node:fs/promises';
import { connect as http2Connect } from 'node:http2';
import { createSign, randomUUID } from 'node:crypto';
import { schnorr } from '@noble/curves/secp256k1';
import { sha256 } from '@noble/hashes/sha256';
import { bytesToHex, utf8ToBytes } from '@noble/hashes/utils';
import WebSocket from 'ws';

// The event kind cubechat frames travel as, and the tag a relay indexes
// recipients by. Both come from `nostr_transport.dart` and must not drift.
const FRAME_KIND = 1059;
const RECIPIENT_TAG = 'p';

// A registration is itself a Nostr event, signed by the key it registers. Its
// own kind, so it can never be confused with a frame — and so a relay would
// simply ignore one if a phone ever published it by mistake.
const REGISTER_KIND = 24242;

// Registrations older than this are refused. Without a window a captured
// registration could be replayed forever to keep a token alive after the phone
// that owned it asked to be forgotten.
const REGISTER_MAX_AGE_SECONDS = 5 * 60;

const PORT = Number(process.env.PORT || 8080);
const RELAYS = (process.env.RELAYS || 'wss://nos.lol,wss://relay.primal.net')
  .split(',')
  .map((url) => url.trim())
  .filter(Boolean);

const APNS_HOST = process.env.APNS_HOST || 'https://api.push.apple.com';
const APNS_TOPIC = process.env.APNS_TOPIC || 'app.cubechat';
const APNS_KEY_ID = process.env.APNS_KEY_ID || '';
const APNS_TEAM_ID = process.env.APNS_TEAM_ID || '';
const APNS_KEY_PATH = process.env.APNS_KEY_PATH || './AuthKey.p8';

const STORE_PATH = process.env.STORE_PATH || './tokens.json';

/** npub (hex) -> { token, updatedAt } */
const tokens = new Map();

// ---------------------------------------------------------------------------
// The registry
// ---------------------------------------------------------------------------

async function loadStore() {
  try {
    const raw = JSON.parse(await readFile(STORE_PATH, 'utf8'));
    for (const [npub, entry] of Object.entries(raw)) {
      if (typeof entry?.token === 'string') tokens.set(npub, entry);
    }
    log('store', `${tokens.size} token(s) loaded`);
  } catch (error) {
    if (error.code !== 'ENOENT') log('store', `load failed: ${error.message}`);
  }
}

let writing = null;
let writeAgain = false;

// Written through a temporary file and renamed, because the alternative is a
// half-written registry after a restart at the wrong moment — and the failure
// mode of that is silence, which is the one failure this whole service exists
// to prevent.
async function saveStore() {
  if (writing) {
    writeAgain = true;
    return writing;
  }
  writing = (async () => {
    const body = JSON.stringify(Object.fromEntries(tokens), null, 2);
    const temp = `${STORE_PATH}.${randomUUID()}`;
    await writeFile(temp, body);
    await rename(temp, STORE_PATH);
  })()
    .catch((error) => log('store', `save failed: ${error.message}`))
    .finally(() => {
      writing = null;
      if (writeAgain) {
        writeAgain = false;
        void saveStore();
      }
    });
  return writing;
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

/// NIP-01's canonical form, byte for byte the same one the app hashes.
function serializeForId(event) {
  return JSON.stringify([
    0,
    event.pubkey,
    event.created_at,
    event.kind,
    event.tags,
    event.content,
  ]);
}

/// True when this event is what it claims to be.
///
/// The id has to be the hash of the canonical form and the signature has to
/// verify against the pubkey in it. Together they are what makes a registration
/// unforgeable: without this anybody could register their own token against
/// somebody else's npub and turn the service into an oracle for "did they get
/// mail".
function verifyEvent(event) {
  if (
    typeof event?.pubkey !== 'string' ||
    typeof event?.id !== 'string' ||
    typeof event?.sig !== 'string' ||
    typeof event?.content !== 'string' ||
    typeof event?.created_at !== 'number' ||
    !Array.isArray(event?.tags)
  ) {
    return false;
  }
  if (!/^[0-9a-f]{64}$/.test(event.pubkey)) return false;
  if (!/^[0-9a-f]{64}$/.test(event.id)) return false;
  if (!/^[0-9a-f]{128}$/.test(event.sig)) return false;
  const id = bytesToHex(sha256(utf8ToBytes(serializeForId(event))));
  if (id !== event.id) return false;
  try {
    return schnorr.verify(event.sig, event.id, event.pubkey);
  } catch {
    return false;
  }
}

/// A device token, or null when the content is not one.
///
/// APNs tokens are 32 bytes of hex. Checked rather than trusted because this
/// string is handed straight to Apple, and a registry full of rubbish is a
/// registry that spends its rate limit on nothing.
function deviceTokenOf(content) {
  const token = content.trim().toLowerCase();
  return /^[0-9a-f]{64,200}$/.test(token) ? token : null;
}

function handleRegister(event) {
  if (!verifyEvent(event)) return { ok: false, reason: 'signature' };
  if (event.kind !== REGISTER_KIND) return { ok: false, reason: 'kind' };
  const age = Math.abs(Math.floor(Date.now() / 1000) - event.created_at);
  if (age > REGISTER_MAX_AGE_SECONDS) return { ok: false, reason: 'stale' };

  // An empty content is how a phone says "forget me": the same signed shape,
  // so the right to be forgotten needs the same key as the right to register.
  if (event.content.trim() === '') {
    const had = tokens.delete(event.pubkey);
    if (had) {
      void saveStore();
      resubscribe();
      log('register', `${short(event.pubkey)} unregistered`);
    }
    return { ok: true, registered: false };
  }

  const token = deviceTokenOf(event.content);
  if (!token) return { ok: false, reason: 'token' };

  const before = tokens.get(event.pubkey)?.token;
  tokens.set(event.pubkey, { token, updatedAt: event.created_at });
  void saveStore();
  // Only when the set of npubs changed. A phone re-registering the same token
  // on every launch must not cost the relays a new subscription each time.
  if (before === undefined) resubscribe();
  log(
    'register',
    `${short(event.pubkey)} ${before === token ? 'refreshed' : 'registered'}`,
  );
  return { ok: true, registered: true };
}

// ---------------------------------------------------------------------------
// APNs
// ---------------------------------------------------------------------------

let apnsKey = null;
let apnsJwt = null;
let apnsJwtIssuedAt = 0;
let apnsSession = null;

/// Apple refuses a token older than an hour and rate-limits one refreshed more
/// often than every twenty minutes, so it is minted on the half hour.
function apnsAuthorization() {
  const now = Math.floor(Date.now() / 1000);
  if (apnsJwt && now - apnsJwtIssuedAt < 30 * 60) return apnsJwt;
  const header = base64Url(
    JSON.stringify({ alg: 'ES256', kid: APNS_KEY_ID, typ: 'JWT' }),
  );
  const claims = base64Url(JSON.stringify({ iss: APNS_TEAM_ID, iat: now }));
  const signer = createSign('SHA256');
  signer.update(`${header}.${claims}`);
  const signature = signer
    .sign({ key: apnsKey, dsaEncoding: 'ieee-p1363' })
    .toString('base64url');
  apnsJwt = `${header}.${claims}.${signature}`;
  apnsJwtIssuedAt = now;
  return apnsJwt;
}

function base64Url(text) {
  return Buffer.from(text).toString('base64url');
}

/// One HTTP/2 session, kept open. Apple expects it: a connection per push is
/// the thing their documentation asks you not to do, and on a phone-sized
/// service it is most of the latency.
function apnsConnection() {
  if (apnsSession && !apnsSession.closed && !apnsSession.destroyed) {
    return apnsSession;
  }
  apnsSession = http2Connect(APNS_HOST);
  apnsSession.on('error', (error) => {
    log('apns', `session error: ${error.message}`);
    apnsSession = null;
  });
  apnsSession.on('close', () => {
    apnsSession = null;
  });
  return apnsSession;
}

/// The push itself: an alert with a fixed string and nothing else in it.
///
/// An alert rather than a silent `content-available`, and that is the whole
/// design. Silent pushes are throttled to a handful an hour at the system's
/// discretion, are not delivered at all in Low Power Mode, and are never
/// delivered to an app the user has swiped away — which is precisely the case
/// this exists for. An alert is delivered.
///
/// What it costs is that the banner says the same thing every time. The app
/// fetches the message from the relay and decrypts it locally when it opens.
async function sendPush(npub, token) {
  const payload = JSON.stringify({
    aps: {
      alert: { 'loc-key': 'PUSH_NEW_MESSAGE' },
      sound: 'default',
      // Collapsed by sender, so ten messages while the phone is in a pocket
      // are one banner rather than ten. The app shows the real list when it
      // opens; a stack of identical placeholders helps nobody.
      'thread-id': 'cubechat',
      badge: 1,
    },
  });

  return new Promise((resolve) => {
    let request;
    try {
      request = apnsConnection().request({
        ':method': 'POST',
        ':path': `/3/device/${token}`,
        authorization: `bearer ${apnsAuthorization()}`,
        'apns-topic': APNS_TOPIC,
        'apns-push-type': 'alert',
        'apns-priority': '10',
        'apns-collapse-id': 'cubechat',
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(payload),
      });
    } catch (error) {
      log('apns', `request failed for ${short(npub)}: ${error.message}`);
      resolve(false);
      return;
    }

    let status = 0;
    let body = '';
    request.on('response', (headers) => {
      status = Number(headers[':status']);
    });
    request.setEncoding('utf8');
    request.on('data', (chunk) => {
      body += chunk;
    });
    request.on('error', (error) => {
      log('apns', `stream error for ${short(npub)}: ${error.message}`);
      resolve(false);
    });
    request.on('end', () => {
      if (status === 200) {
        resolve(true);
        return;
      }
      // A token Apple has retired is a phone that reinstalled or removed the
      // app. Dropping it here is what stops the registry filling with addresses
      // that will never answer again.
      const reason = safeReason(body);
      if (status === 410 || reason === 'BadDeviceToken') {
        tokens.delete(npub);
        void saveStore();
        resubscribe();
        log('apns', `${short(npub)} token retired (${reason || status})`);
      } else {
        log('apns', `${short(npub)} refused: ${status} ${reason || body}`);
      }
      resolve(false);
    });
    request.end(payload);
  });
}

function safeReason(body) {
  try {
    return JSON.parse(body)?.reason ?? '';
  } catch {
    return '';
  }
}

// ---------------------------------------------------------------------------
// Relays
// ---------------------------------------------------------------------------

const sockets = new Map();

/// Events seen recently, so the same message arriving from two relays is one
/// push. Bounded, because this runs forever.
const seen = new Map();
const SEEN_MAX = 5000;

function alreadySeen(id) {
  if (seen.has(id)) return true;
  seen.set(id, Date.now());
  if (seen.size > SEEN_MAX) {
    for (const key of seen.keys()) {
      seen.delete(key);
      if (seen.size <= SEEN_MAX * 0.9) break;
    }
  }
  return false;
}

function connectRelay(url) {
  if (sockets.has(url)) return;
  const socket = new WebSocket(url);
  sockets.set(url, socket);

  socket.on('open', () => {
    log('relay', `${url} up`);
    subscribeOn(socket);
  });

  socket.on('message', (data) => {
    let frame;
    try {
      frame = JSON.parse(data.toString());
    } catch {
      return;
    }
    if (!Array.isArray(frame) || frame[0] !== 'EVENT') return;
    const event = frame[2];
    if (!event || event.kind !== FRAME_KIND) return;
    if (alreadySeen(event.id)) return;
    for (const tag of event.tags ?? []) {
      if (tag[0] !== RECIPIENT_TAG) continue;
      const entry = tokens.get(tag[1]);
      if (!entry) continue;
      log('wake', `${short(tag[1])} has mail`);
      void sendPush(tag[1], entry.token);
    }
  });

  const reopen = () => {
    sockets.delete(url);
    setTimeout(() => connectRelay(url), 5000);
  };
  socket.on('close', () => {
    log('relay', `${url} down`);
    reopen();
  });
  socket.on('error', (error) => {
    log('relay', `${url}: ${error.message}`);
    try {
      socket.close();
    } catch {
      // Already going.
    }
  });
}

function subscribeOn(socket) {
  if (socket.readyState !== WebSocket.OPEN) return;
  const npubs = [...tokens.keys()];
  if (npubs.length === 0) return;
  // `since` is now: the backlog is not our business. A message that arrived
  // while this service was down has already been waiting, and waking a phone
  // for it an hour later is a notification about the past.
  const filter = {
    kinds: [FRAME_KIND],
    '#p': npubs,
    since: Math.floor(Date.now() / 1000),
  };
  socket.send(JSON.stringify(['REQ', 'wake', filter]));
}

let resubscribeTimer = null;

/// Debounced: a run of phones registering at once — which is what happens when
/// a build ships — must not send one REQ per phone to every relay.
function resubscribe() {
  if (resubscribeTimer) clearTimeout(resubscribeTimer);
  resubscribeTimer = setTimeout(() => {
    resubscribeTimer = null;
    for (const socket of sockets.values()) {
      if (socket.readyState !== WebSocket.OPEN) continue;
      socket.send(JSON.stringify(['CLOSE', 'wake']));
      subscribeOn(socket);
    }
    log('relay', `watching ${tokens.size} npub(s)`);
  }, 2000);
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

function readBody(request, limit = 8 * 1024) {
  return new Promise((resolve, reject) => {
    let body = '';
    request.on('data', (chunk) => {
      body += chunk;
      if (body.length > limit) {
        reject(new Error('too large'));
        request.destroy();
      }
    });
    request.on('end', () => resolve(body));
    request.on('error', reject);
  });
}

const server = createServer(async (request, response) => {
  if (request.method === 'GET' && request.url === '/health') {
    return json(response, 200, {
      ok: true,
      tokens: tokens.size,
      relays: [...sockets.keys()],
    });
  }
  if (request.method === 'POST' && request.url === '/register') {
    let event;
    try {
      event = JSON.parse(await readBody(request));
    } catch {
      return json(response, 400, { ok: false, reason: 'body' });
    }
    const result = handleRegister(event);
    return json(response, result.ok ? 200 : 400, result);
  }
  return json(response, 404, { ok: false });
});

function json(response, status, body) {
  const text = JSON.stringify(body);
  response.writeHead(status, {
    'content-type': 'application/json',
    'content-length': Buffer.byteLength(text),
  });
  response.end(text);
}

// ---------------------------------------------------------------------------

function short(npub) {
  return npub.slice(0, 8);
}

function log(scope, message) {
  process.stdout.write(
    `${new Date().toISOString()} [${scope}] ${message}\n`,
  );
}

async function main() {
  await loadStore();
  try {
    apnsKey = await readFile(APNS_KEY_PATH, 'utf8');
  } catch (error) {
    // Started without a key on purpose during setup: the registry and the relay
    // half still work, so `/health` and registration can be checked before
    // Apple is in the picture at all. Every push will fail loudly until it is
    // there, which is the right kind of broken.
    log('apns', `no key at ${APNS_KEY_PATH} (${error.code}) — pushes will fail`);
  }
  for (const url of RELAYS) connectRelay(url);
  server.listen(PORT, () => log('http', `listening on ${PORT}`));
}

void main();
