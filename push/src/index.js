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
import { readFile, writeFile, rename, appendFile } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { connect as http2Connect } from 'node:http2';
import {
  createSign, createHmac, randomUUID, randomBytes, timingSafeEqual,
  createPrivateKey, sign as cryptoSign,
} from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { schnorr } from '@noble/curves/secp256k1';
import { sha256 } from '@noble/hashes/sha256';
import { bytesToHex, utf8ToBytes } from '@noble/hashes/utils';
import WebSocket from 'ws';

// The event kind cubechat frames travel as, and the tag a relay indexes
// recipients by. Both come from `nostr_transport.dart` and must not drift.
const FRAME_KIND = 1059;
/// What `/health` reports, so a deployment can be identified rather than
/// assumed. Bump it in the same commit as any change to this file.
const VERSION = '2026-09-25-channel-report-fingerprint';

const RECIPIENT_TAG = 'p';

/// Set by the sender on the events a person would want to be woken for.
///
/// See `kWakeTag` in the app. Text messages and channel posts carry it; media
/// chunks, read receipts, typing notices and presence do not.
const WAKE_TAG = 'w';

/// Set by the sender beside WAKE_TAG on a call invite. See `kCallTag` in the
/// app. It says a call is ringing, never who is calling.
const CALL_TAG = 'c';

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

// Firebase Cloud Messaging — the Android half of the same doorbell.
//
// A service-account JSON downloaded from the Firebase console. Only three of
// its fields are used: the project id names the endpoint, and the client email
// and private key sign the assertion that buys an access token. Absent means
// Android registrations are accepted and never rung, which is what every
// deployment did before this existed.
const FCM_KEY_PATH = process.env.FCM_KEY_PATH || './fcm-service-account.json';

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

/// Which push network a registration belongs to.
///
/// Carried on the event rather than guessed from the token's shape. The shapes
/// do differ — APNs is hex, FCM is a long opaque string with punctuation in it
/// — but a rule inferred from today's formats is a rule that breaks the day
/// either vendor changes one, silently and in production.
function platformOf(event) {
  for (const tag of event.tags ?? []) {
    if (tag[0] !== 'platform' || typeof tag[1] !== 'string') continue;
    const value = tag[1].trim().toLowerCase();
    if (value === 'android' || value === 'ios') return value;
  }
  // Absent means iOS: every build that registered before Android could was an
  // iPhone, and a stored registration must not change meaning under an upgrade.
  return 'ios';
}

/// Checked rather than trusted, because this string is handed straight to a
/// vendor and a registry full of rubbish spends its rate limit on nothing.
///
/// APNs is 32 bytes of hex. FCM is an opaque token — Google documents no
/// format and has changed its length more than once — so the check is only
/// that it is plausible and free of anything that could break out of a JSON
/// body or a URL path.
function deviceTokenOf(content, platform) {
  const raw = content.trim();
  if (platform === 'android') {
    return /^[A-Za-z0-9_:.-]{100,4096}$/.test(raw) ? raw : null;
  }
  const token = raw.toLowerCase();
  return /^[0-9a-f]{64,200}$/.test(token) ? token : null;
}

/// What the banner says, per language the app can be set to.
///
/// The server cannot decrypt anything, so this is the whole of the text — the
/// message itself is fetched from the relay and opened on the phone. Keep these
/// in step with the app's supported locales: an unknown code falls back to the
/// same default the app builds with rather than showing nothing.
const ALERT_BODY = {
  en: 'New message',
  uk: 'Нове повідомлення',
};

/// The same, for an event the sender marked as a call invite (`CALL_TAG`).
///
/// Said as a call so the words are right on a phone that cannot ring properly
/// — an iPhone with no CallKit yet, an Android whose app could not start in
/// time. Same languages as `ALERT_BODY`, and the keys must stay the same set.
const CALL_BODY = {
  en: 'Incoming call',
  uk: 'Вхідний дзвінок',
};

const DEFAULT_LANG = 'en';

/// The banner text for a language and a kind of event. Exported for the test.
export { voipTokenOf };

export function pushBody(lang, { call = false } = {}) {
  const table = call ? CALL_BODY : ALERT_BODY;
  return table[lang] || table[DEFAULT_LANG];
}

/// The language tag from a registration, or the default.
///
/// Tags are part of what the signature covers, so this cannot be set for
/// somebody else's npub or changed in flight. Validated against the table
/// rather than passed through: the value ends up selecting a string, and an
/// unknown one should degrade to English, not to `undefined`.
function languageOf(event) {
  const tags = Array.isArray(event?.tags) ? event.tags : [];
  for (const tag of tags) {
    if (Array.isArray(tag) && tag[0] === 'lang' && typeof tag[1] === 'string') {
      const code = tag[1].trim().toLowerCase().slice(0, 2);
      if (Object.hasOwn(ALERT_BODY, code)) return code;
    }
  }
  return DEFAULT_LANG;
}

/// The PushKit token from an iPhone registration, or null.
///
/// A tag rather than the content, because the content is the alert token and
/// an empty content already means "forget me". Signed with everything else, so
/// nobody can point somebody else's calls at their own phone. Only iOS has
/// one; an Android registration carrying the tag is not believed.
function voipTokenOf(event, platform) {
  if (platform !== 'ios') return null;
  for (const tag of event.tags ?? []) {
    if (!Array.isArray(tag) || tag[0] !== 'voip' || typeof tag[1] !== 'string') continue;
    const value = tag[1].trim().toLowerCase();
    if (/^[0-9a-f]{64}$/.test(value)) return value;
  }
  return null;
}

function handleRegister(event, { bans = adminBans } = {}) {
  if (!verifyEvent(event)) return { ok: false, reason: 'signature' };
  if (event.kind !== REGISTER_KIND) return { ok: false, reason: 'kind' };
  // Checked right after the signature verifies and before anything else, for
  // the same reason `handleTurn` checks it here rather than earlier: an
  // unsigned request must not be a way to learn who is banned (S3 spec). A
  // banned identity is refused before its registration is ever looked at —
  // it never even reaches the "is this a TURN request replayed here"
  // check below, so a banned phone can't use either path to keep a token on
  // file.
  if (bans.isBannedNpub(event.pubkey)) {
    return { ok: false, reason: 'banned', status: 403 };
  }
  // A TURN request is this same kind, signed by the same key, with empty
  // content — and empty content is how a phone asks to be forgotten. Without
  // this, one phone's TURN request replayed here would switch that phone's
  // notifications off, silently. /turn already refuses a registration; this
  // is the other direction, and it was the dangerous one. A real registration
  // never carries a purpose tag (see push_registration.dart), so any tag of
  // that name means the proof was minted for something else.
  if (event.tags.some((tag) => Array.isArray(tag) && tag[0] === 'action')) {
    return { ok: false, reason: 'purpose' };
  }
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

  const platform = platformOf(event);
  const token = deviceTokenOf(event.content, platform);
  if (!token) return { ok: false, reason: 'token' };
  const lang = languageOf(event);
  const voip = voipTokenOf(event, platform);

  const previous = tokens.get(event.pubkey);
  const before = previous?.token;
  tokens.set(event.pubkey, {
    token,
    updatedAt: event.created_at,
    lang,
    platform,
    // Carried over only when the token is the same one. Which APNs host a
    // token belongs to is learned by being refused once (see hostsFor), and
    // a phone re-registers on every launch — dropping it here would make the
    // service re-learn it, at the cost of a wasted round trip, forever. A
    // *new* token may well be a new environment, so that keeps nothing.
    host: token === before ? previous?.host : undefined,
    // Kept from before only for the same install. PushKit hands the token over
    // a moment after launch, so a registration can leave before it exists; a
    // phone that has not been reinstalled still has the one it sent last time.
    voip: voip ?? (token === before ? previous?.voip : undefined),
  });
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
/// One session per host, because there are two hosts and a phone can be on
/// either.
const apnsSessions = new Map();

const APNS_PRODUCTION = 'https://api.push.apple.com';
const APNS_SANDBOX = 'https://api.sandbox.push.apple.com';

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
function apnsConnection(host) {
  const existing = apnsSessions.get(host);
  if (existing && !existing.closed && !existing.destroyed) return existing;
  const session = http2Connect(host);
  session.on('error', (error) => {
    log('apns', `session error (${host}): ${error.message}`);
    apnsSessions.delete(host);
  });
  session.on('close', () => apnsSessions.delete(host));
  apnsSessions.set(host, session);
  return session;
}

/// Which of Apple's two hosts a token belongs to.
///
/// A token minted by a sideloaded or Xcode build is a *sandbox* token; one from
/// TestFlight or the App Store is a *production* token, and each host refuses
/// the other's with `BadDeviceToken` — a message that reads like a broken token
/// rather than the wrong address, and costs an evening every time.
///
/// So the host is not configured, it is discovered: try, and on that one error
/// try the other. What worked is remembered per token, so the second push to
/// the same phone goes straight there. That is also the only way to serve a
/// sideloaded phone and a TestFlight phone at once, which one setting cannot
/// do however carefully it is chosen.
function hostsFor(npub) {
  const known = tokens.get(npub)?.host;
  if (known) return [known, known === APNS_PRODUCTION ? APNS_SANDBOX : APNS_PRODUCTION];
  // The configured one first: it is a hint about which kind of build is being
  // tested right now, and being right first time saves a round trip.
  const first = APNS_HOST === APNS_SANDBOX ? APNS_SANDBOX : APNS_PRODUCTION;
  return [first, first === APNS_PRODUCTION ? APNS_SANDBOX : APNS_PRODUCTION];
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
/// Every attempt, named.
///
/// `token retired (BadDeviceToken)` was the whole story a failure told, and it
/// is not enough to act on: it carries the *second* attempt's reason and never
/// says which host either attempt went to, so "both environments refuse it"
/// and "one environment was asked twice" read identically. That ambiguity cost
/// a diagnosis — the topic, the key and the entitlement were each suspected
/// and cleared while the log said the same eight words each time.
///
/// The token's own shape is worth a line too. A truncated or re-encoded token
/// is refused exactly like a foreign one, and length plus the first bytes tells
/// the two apart without putting the whole address in a log file.
function logAttempt(npub, token, host, result) {
  log(
    'apns',
    `${short(npub)} -> ${envName(host)}: ` +
      `${result.status || 'no response'} ${result.reason || result.body || ''}`.trim() +
      ` [token ${token.length} chars, ${token.slice(0, 8)}…]`,
  );
}

// ---------------------------------------------------------------------------
// FCM
// ---------------------------------------------------------------------------

let fcmAccount = null;
let fcmAccountRead = false;
let fcmToken = null;
let fcmTokenExpiry = 0;

/// The service account, read once. Null when the file is not there, which is a
/// deployment without Android push rather than an error.
async function fcmServiceAccount() {
  if (fcmAccountRead) return fcmAccount;
  fcmAccountRead = true;
  try {
    const raw = JSON.parse(await readFile(FCM_KEY_PATH, 'utf8'));
    if (!raw.project_id || !raw.client_email || !raw.private_key) {
      log('fcm', 'service account is missing project_id/client_email/private_key');
      return null;
    }
    fcmAccount = raw;
    log('fcm', `service account for ${raw.project_id}`);
  } catch (error) {
    if (error.code !== 'ENOENT') {
      log('fcm', `service account unreadable: ${error.message}`);
    } else {
      log('fcm', 'no service account — Android push is off');
    }
  }
  return fcmAccount;
}

/// An OAuth access token for the messaging scope.
///
/// Google wants a bearer token rather than a self-signed JWT the way Apple
/// does, so this is one extra round trip — but only once an hour. Refreshed
/// five minutes early, because a token that expires between the check and the
/// send is a push nobody gets and nobody can explain.
async function fcmAccessToken() {
  const now = Math.floor(Date.now() / 1000);
  if (fcmToken && now < fcmTokenExpiry - 300) return fcmToken;
  const account = await fcmServiceAccount();
  if (!account) return null;

  const header = Buffer.from(
    JSON.stringify({ alg: 'RS256', typ: 'JWT' }),
  ).toString('base64url');
  const claims = Buffer.from(
    JSON.stringify({
      iss: account.client_email,
      scope: 'https://www.googleapis.com/auth/firebase.messaging',
      aud: 'https://oauth2.googleapis.com/token',
      iat: now,
      exp: now + 3600,
    }),
  ).toString('base64url');
  const signer = createSign('RSA-SHA256');
  signer.update(`${header}.${claims}`);
  const assertion =
    `${header}.${claims}.${signer.sign(account.private_key, 'base64url')}`;

  try {
    const response = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion,
      }),
    });
    const body = await response.json();
    if (!response.ok || !body.access_token) {
      log('fcm', `token refused: ${response.status} ${JSON.stringify(body)}`);
      return null;
    }
    fcmToken = body.access_token;
    fcmTokenExpiry = now + (body.expires_in ?? 3600);
    return fcmToken;
  } catch (error) {
    log('fcm', `token request failed: ${error.message}`);
    return null;
  }
}

/// Ring an Android phone.
///
/// A `notification` block rather than a data-only message, for the same reason
/// the APNs payload is an alert and not `content-available`: a data-only
/// message is not shown by the system and needs the app to be alive to draw
/// anything, which is precisely what is not true here. The system draws this
/// one whether or not cubechat is running.
///
/// The body is the same fixed string APNs carries. This service decrypts
/// nothing and has nothing else to say.
async function sendFcm(npub, token, { call = false } = {}) {
  const account = await fcmServiceAccount();
  const access = await fcmAccessToken();
  if (!account || !access) return false;
  const url =
    `https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`;
  // Data, not a notification block, and this is the whole of the change the
  // phone side needed.
  //
  // A `notification` block is drawn by the system before any of the app's code
  // runs, so a phone whose process was alive and about to show a proper
  // notification — sender, face, text — showed the generic one first and had it
  // taken away a moment later. A data message with `priority: high` wakes a
  // swiped-away process exactly as an alert does, so nothing is lost in the
  // case the doorbell exists for; what is gained is that the app decides.
  //
  // The cost, said plainly: a build older than the one that ships with this has
  // no service to receive a data message and its default handler draws nothing,
  // so an older install stops getting push the day this deploys. That is why it
  // goes out with the app build that answers it.
  const payload = {
    message: {
      token,
      // `kind` tells CubechatFcmService to wait for the app's own call screen
      // rather than drawing "new message" over it. Absent for a message, so a
      // build that predates it reads exactly what it always did.
      data: call
        ? { body: bodyFor(npub, { call }), kind: 'call' }
        : { body: bodyFor(npub) },
      android: {
        // Wake it now. The alternative is `normal`, which lets the system hold
        // the message until it next feels like waking the device — the same
        // trade Apple's priority 10 avoids.
        priority: 'high',
        // No `android.notification` block: FCM only reads one when there is a
        // `notification` to draw, and there is not any more. What the banner
        // looks like — its channel, its icon, the tag the app cancels it by —
        // is decided in `CubechatFcmService`, which is the only place that can
        // also decide whether to draw one at all.
      },
    },
  };
  try {
    const response = await fetch(url, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${access}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify(payload),
    });
    if (response.status === 200) {
      log('fcm', `${short(npub)} -> delivered [token ${token.length} chars]`);
      return true;
    }
    const text = await response.text();
    log('fcm', `${short(npub)} -> ${response.status} ${text.slice(0, 200)}`);
    // Google's word for "this token answers to nobody": the app was
    // uninstalled, or the token was replaced. Same meaning as APNs 410.
    if (
      response.status === 404 ||
      (response.status === 400 && text.includes('UNREGISTERED'))
    ) {
      forgetToken(npub, `fcm ${response.status}`);
    }
    return false;
  } catch (error) {
    log('fcm', `${short(npub)} -> request failed: ${error.message}`);
    return false;
  }
}

/// Ring an iPhone for a call through PushKit, so it can show CallKit's screen
/// even when the app has been swiped away.
///
/// The ordinary alert is only a banner, and "calls do not arrive on iOS when the
/// app is fully closed" was the report: a banner is not a call. A VoIP push
/// launches the app in the background and iOS requires it to report a call to
/// CallKit before it does anything else — which is exactly the full-screen
/// incoming call being asked for.
///
/// True when Apple took it. A token Apple refuses outright is forgotten, and
/// the caller falls back to the alert, so a broken VoIP token costs one call a
/// banner instead of costing every call its doorbell.
async function sendVoip(npub, voip, eventId) {
  const [first, second] = hostsFor(npub);
  let attempt = await pushTo(npub, voip, first, { voip: true, eventId });
  logAttempt(npub, voip, first, attempt);
  if (attempt.status === 200) return true;
  if (attempt.reason === 'BadDeviceToken') {
    const retry = await pushTo(npub, voip, second, { voip: true, eventId });
    logAttempt(npub, voip, second, retry);
    if (retry.status === 200) return true;
    attempt = retry;
  }
  const dead = ['BadDeviceToken', 'DeviceTokenNotForTopic', 'Unregistered', 'TopicDisallowed'];
  if (attempt.status === 410 || dead.includes(attempt.reason)) {
    const entry = tokens.get(npub);
    if (entry?.voip === voip) {
      delete entry.voip;
      void saveStore();
      log('voip', `${short(npub)} voip token retired (${attempt.reason || attempt.status})`);
    }
  }
  return false;
}

async function sendPush(npub, token, { call = false, eventId = '' } = {}) {
  const voip = tokens.get(npub)?.voip;
  if (call && voip && tokens.get(npub)?.platform !== 'android') {
    if (await sendVoip(npub, voip, eventId)) return true;
  }
  // Android goes to Google, everything else to Apple. The two networks share
  // nothing but this doorbell's intent, so the split is here rather than
  // threaded through the APNs code below.
  if (tokens.get(npub)?.platform === 'android') {
    return sendFcm(npub, token, { call });
  }
  const [first, second] = hostsFor(npub);
  const attempt = await pushTo(npub, token, first, { call });
  logAttempt(npub, token, first, attempt);
  if (attempt.status === 200) {
    rememberHost(npub, first);
    return true;
  }
  // The one error that means "right token, wrong address". Everything else is
  // final: a rejected payload or a retired token says the same thing on both
  // hosts, and trying twice would only double the log.
  if (attempt.reason === 'BadDeviceToken') {
    const retry = await pushTo(npub, token, second, { call });
    logAttempt(npub, token, second, retry);
    if (retry.status === 200) {
      log('apns', `${short(npub)} is a ${envName(second)} token`);
      rememberHost(npub, second);
      return true;
    }
    // Refused by both. Now it really is a token that answers to nobody —
    // reinstalled, or the app removed — and keeping it costs a push per
    // message forever.
    if (retry.reason === 'BadDeviceToken' || retry.status === 410) {
      forgetToken(npub, retry.reason || retry.status);
      return false;
    }
    log('apns', `${short(npub)} refused on both: ${retry.status} ${retry.reason}`);
    return false;
  }
  if (attempt.status === 410) {
    forgetToken(npub, attempt.reason || attempt.status);
    return false;
  }
  log(
    'apns',
    `${short(npub)} refused: ${attempt.status} ${attempt.reason || attempt.body}`,
  );
  return false;
}

/// The banner text for whoever this is going to.
///
/// A registry entry written before languages existed has no `lang`, and so does
/// one from a phone running an older build. Both get English rather than an
/// empty banner.
function bodyFor(npub, { call = false } = {}) {
  return pushBody(tokens.get(npub)?.lang, { call });
}

function envName(host) {
  return host === APNS_SANDBOX ? 'sandbox' : 'production';
}

function rememberHost(npub, host) {
  const entry = tokens.get(npub);
  if (!entry || entry.host === host) return;
  entry.host = host;
  void saveStore();
}

function forgetToken(npub, why) {
  tokens.delete(npub);
  void saveStore();
  resubscribe();
  log('apns', `${short(npub)} token retired (${why})`);
}

/// One attempt against one host. Returns what Apple said rather than deciding
/// what it means, because the meaning depends on which attempt this was.
function pushTo(npub, token, host, { call = false, voip = false, eventId = '' } = {}) {
  // A VoIP push carries no alert: the app reports the call to CallKit itself,
  // the moment iOS hands it this, and CallKit draws the screen. Which call it
  // is, is inside the relay event; the id is only there for the log.
  const payload = voip ? JSON.stringify({ aps: {}, type: 'call', id: eventId }) : JSON.stringify({
    aps: {
      // The text itself, not a `loc-key`. That is what this sent until
      // 2026-08-31, and it never worked: `loc-key` names an entry in the
      // app's Localizable.strings, this Flutter app ships no such file
      // (its translations are .arb, compiled into Dart), and iOS falls back
      // to displaying the key. Every banner would have read
      // "PUSH_NEW_MESSAGE". Shipping the string from here needs no iOS
      // resource at all, and the language rides in the signed registration.
      alert: { body: bodyFor(npub, { call }) },
      sound: 'default',
      // Grouped, not collapsed. `thread-id` stacks the banners together in
      // Notification Centre; it does not replace one with the next, which is
      // what `apns-collapse-id` did below until 2026-09-02.
      //
      // That collapsing was deliberate once — ten identical "New message"
      // banners were held to help nobody — and it was wrong in practice.
      // Replacing the banner is indistinguishable from never having sent it:
      // the phone owner sees one notice, no matter how many people wrote,
      // and reads that as messages going missing. Asked for and changed.
      'thread-id': 'cubechat',
      // Deliberately no `badge`. It was a hardcoded 1, which was already a
      // guess and becomes a contradiction next to five banners. The server
      // cannot count unread mail — it cannot read any of it, and it never
      // learns what has been opened — so it now asserts nothing and leaves
      // the badge to the app, which knows.
    },
  });

  return new Promise((resolve) => {
    let request;
    try {
      request = apnsConnection(host).request({
        ':method': 'POST',
        ':path': `/3/device/${token}`,
        authorization: `bearer ${apnsAuthorization()}`,
        'apns-topic': voip ? `${APNS_TOPIC}.voip` : APNS_TOPIC,
        'apns-push-type': voip ? 'voip' : 'alert',
        'apns-priority': '10',
        // A call nobody could be rung for a minute ago is over. Without this
        // APNs stores a VoIP push for an offline phone and rings it later for
        // a call that ended long before.
        ...(voip ? { 'apns-expiration': String(Math.floor(Date.now() / 1000) + 60) } : {}),
        // No `apns-collapse-id`. With one there, every push carried the same
        // id and APNs treats that as "this replaces the last one" — so a
        // second message overwrote the first banner instead of arriving
        // beside it. Without it each push stands on its own.
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(payload),
      });
    } catch (error) {
      log('apns', `request failed for ${short(npub)}: ${error.message}`);
      resolve({ status: 0, reason: '', body: error.message });
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
      resolve({ status: 0, reason: '', body: error.message });
    });
    request.on('end', () => {
      resolve({ status, reason: safeReason(body), body });
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

/// When each recipient was last rung, so a flood of events is not a flood of
/// pushes.
///
/// `seen` dedups one *event* arriving from several relays. It does nothing
/// about many different events aimed at one person, and nothing about who
/// sent them: the wake tag is a public recipient id, so anybody able to
/// publish to a relay we watch can address as many events at somebody as they
/// like and this would have rung for every one. A signature check would not
/// help — a spammer signs with their own key quite happily — so the bound has
/// to be on the ringing, not on the sender.
///
/// **The per-message gap is gone; the hourly ceiling is what bounds a flood.**
///
/// It read: "coalescing rather than dropping, and it costs nothing real: this
/// push says 'you have mail' and nothing else. Two events ten seconds apart
/// mean one doorbell either way; the app fetches everything waiting once it is
/// awake." True of *waking*, and the reason the ceiling stays. False of what
/// the phone's owner is actually looking at.
///
/// While the app is closed, the doorbell's banners **are** the notification
/// list — the app is not running to draw its own — so one every fifteen
/// seconds meant six stickers appearing as two. Reported as exactly that, and
/// it is the same complaint that removed `apns-collapse-id` on 2026-09-02: a
/// notice that stands in for several is read as messages going missing.
///
/// So the bound is the ceiling alone. A burst of six rings six times, which is
/// what happened; a burst of six hundred rings sixty and then stops, which is
/// what the ceiling is for. The gap was a second limiter doing the first one's
/// job badly and costing the truth.
const lastWake = new Map();
const WAKE_MAX_PER_HOUR = 60;
const HOUR_MS = 3_600_000;

function shouldWake(npub) {
  const now = Date.now();
  const entry = lastWake.get(npub);
  if (!entry) {
    lastWake.set(npub, { at: now, hourStart: now, count: 1 });
    return true;
  }
  if (now - entry.hourStart >= HOUR_MS) {
    entry.hourStart = now;
    entry.count = 0;
  }
  if (entry.count >= WAKE_MAX_PER_HOUR) {
    // One line an hour, not one a message: the point of the ceiling is to stop
    // a flood, and a log that floods alongside it defeats half of that.
    if (entry.count === WAKE_MAX_PER_HOUR) {
      log('wake', `${short(npub)} over the hourly ceiling — holding`);
      entry.count++;
    }
    return false;
  }
  entry.at = now;
  entry.count++;
  return true;
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
    if (typeof event.id !== 'string' || !Array.isArray(event.tags)) return;

    // Only what the sender marked as worth waking somebody for.
    //
    // The app has always set this tag, and this has always ignored it: a
    // doorbell rang for *every* event addressed to a registered npub. Most
    // events are not news. A photo is one manifest and then five to thirty
    // chunks, each its own relay event, so a single sticker rang the
    // recipient's phone eight times and three of them rang it thirty — which
    // is what "three stickers, thirty-four messages" was counting. It was
    // counting correctly; the events were the problem.
    //
    // The other side of it is the machinery: read receipts, typing notices,
    // presence, the copy-restriction note. None of them carry the tag either,
    // and none of them should put a banner on a locked phone.
    //
    // An event without the tag is still delivered — the phone reads it the
    // moment it is awake for any other reason. This decides only whether to
    // wake it.
    if (!event.tags.some((t) => Array.isArray(t) && t[0] === WAKE_TAG)) return;

    if (alreadySeen(event.id)) return;
    const call = event.tags.some((t) => Array.isArray(t) && t[0] === CALL_TAG);
    for (const tag of event.tags) {
      if (!Array.isArray(tag) || tag[0] !== RECIPIENT_TAG) continue;
      if (typeof tag[1] !== 'string') continue;
      const entry = tokens.get(tag[1]);
      if (!entry) continue;
      if (!shouldWake(tag[1])) continue;
      log('wake', `${short(tag[1])} has ${call ? 'a call' : 'mail'}`);
      void sendPush(tag[1], entry.token, { call, eventId: event.id });
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
  // `#w` is what makes this a doorbell rather than a smoke alarm.
  //
  // Without it the filter matched every frame addressed to a registered npub,
  // and most frames are housekeeping: a presence heartbeat every 70 seconds,
  // read receipts, announcements, typing notices. A phone with the app closed
  // got a "New message" banner about once a minute with no message behind it —
  // reported, and worse than no notification at all, because it teaches the
  // owner to ignore the real ones.
  //
  // This service cannot tell the two apart, and should not be able to: it
  // holds no key and decrypts nothing. So the sender marks the frames a person
  // would want to be woken for, in the clear, and this asks for only those.
  // See `kWakeTag` in nostr_transport.dart for what that costs.
  //
  // A build that predates the tag rings no doorbell at all. That is the safe
  // direction and it cost nothing when it shipped: push had one registered
  // device in the world, and it took the new build the same day.
  const filter = {
    kinds: [FRAME_KIND],
    '#p': npubs,
    '#w': ['1'],
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

export const server = createServer(async (request, response) => {
  if (request.method === 'GET' && request.url === '/health') {
    return json(response, 200, {
      ok: true,
      // Which code is actually running.
      //
      // Twice now a change here has been written, committed, and then had to be
      // taken on trust — `scp` and a restart leave nothing behind that says
      // what arrived, and the only other evidence was the order the relays
      // happened to reconnect in. A deployment that cannot be identified is a
      // deployment that gets debugged as if it were the source.
      //
      // Bumped by hand, in the same commit as whatever it describes.
      version: VERSION,
      tokens: tokens.size,
      // Split by platform, because "tokens:1" stopped answering the question
      // the moment there were two kinds. A deployment with no FCM service
      // account accepts Android registrations and rings none of them, and this
      // is where that shows.
      ios: [...tokens.values()].filter((t) => t.platform !== 'android').length,
      android: [...tokens.values()].filter((t) => t.platform === 'android').length,
      fcm: fcmAccountRead ? (fcmAccount?.project_id ?? null) : 'not read yet',
      relays: [...sockets.keys()],
    });
  }
  if (request.method === 'POST' && request.url === '/turn') {
    let event;
    try {
      event = JSON.parse(await readBody(request));
    } catch {
      return json(response, 400, { ok: false, reason: 'body' });
    }
    const result = handleTurn(event);
    response.setHeader('cache-control', 'no-store');
    return json(response, result.status, result.body);
  }
  if (request.method === 'POST' && request.url === '/report') {
    let event;
    try {
      event = JSON.parse(await readBody(request));
    } catch {
      return json(response, 400, { ok: false, reason: 'body' });
    }
    const result = await handleReport(event, {
      limiter: reportLimiter, store: reportStore, notify: logReport,
    });
    response.setHeader('cache-control', 'no-store');
    return json(response, result.status, result.body);
  }
  if (request.method === 'POST' && request.url === '/register') {
    let event;
    try {
      event = JSON.parse(await readBody(request));
    } catch {
      return json(response, 400, { ok: false, reason: 'body' });
    }
    const result = handleRegister(event);
    // `status` is only ever set for the one case that isn't a plain 200/400
    // — a banned npub, which is 403. Everything else keeps the shape this
    // route always had.
    return json(response, result.status ?? (result.ok ? 200 : 400), result);
  }
  if (request.method === 'GET' && request.url === '/banned') {
    const result = handleBanned({ bans: adminBans });
    response.setHeader('cache-control', result.cacheControl);
    return json(response, result.status, result.body);
  }
  if (request.url.startsWith('/admin/')) {
    // Set before any response on this path, including the "body too large"
    // 400 below — every /admin/ response is uncacheable, not just the happy
    // ones.
    response.setHeader('cache-control', 'no-store');
    let body = '';
    try {
      body = await readBody(request);
    } catch {
      return json(response, 400, { ok: false, reason: 'body' });
    }
    const result = await handleAdmin(
      { method: request.method, url: request.url, headers: request.headers, body },
      { store: reportStore, bans: adminBans, remoteAddress: request.socket.remoteAddress },
    );
    return json(response, result.status, result.body);
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
  // Read now rather than on the first Android push, for the same reason the
  // APNs key is read here: "did the key land" is a question asked while
  // deploying, and answering it by waiting for a phone to register and then a
  // message to arrive is not answering it. The boot log now says which of the
  // two networks this deployment can actually reach, and `/health` says the
  // same thing to anyone outside.
  await fcmServiceAccount();
  for (const url of RELAYS) connectRelay(url);
  server.listen(PORT, () => log('http', `listening on ${PORT}`));
}

// Importing the HTTP handler in tests must not connect to production relays,
// load device tokens, or start sending notifications.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  void main();
}

export function turnCredentials({ secret, ttlSeconds, nowSeconds }) {
  if (!secret || !Number.isSafeInteger(ttlSeconds) || ttlSeconds <= 0 ||
      !Number.isSafeInteger(nowSeconds) || nowSeconds < 0) {
    throw new Error('TURN credentials are not configured');
  }
  const username = String(nowSeconds + ttlSeconds);
  const password = createHmac('sha1', secret).update(username).digest('base64');
  return { username, password, ttl: ttlSeconds };
}

export function handleTurn(event, {
  nowSeconds = Math.floor(Date.now() / 1000),
  secret = process.env.TURN_SECRET,
  urls = (process.env.TURN_URLS || '').split(',').map((url) => url.trim()).filter(Boolean),
  bans = adminBans,
} = {}) {
  // A registration signature must not be reusable to obtain TURN access.
  // The purpose is signed too; the client uses the same identity key.
  if (!verifyEvent(event) || event.kind !== REGISTER_KIND ||
      !event.tags.some((tag) => Array.isArray(tag) && tag[0] === 'action' && tag[1] === 'turn')) {
    return { status: 401, body: { ok: false, reason: 'signature' } };
  }
  // Checked only now — after the signature (and the purpose tag) verified —
  // so an unsigned request can't be used to probe who is on the list (S3
  // spec). A banned phone still gets a clean, specific answer rather than the
  // generic 401 `signature`, which is the point: TURN access is refused
  // because of the ban, not because the request looked forged.
  if (bans.isBannedNpub(event.pubkey)) {
    return { status: 403, body: { ok: false, reason: 'banned' } };
  }
  if (!Number.isSafeInteger(event.created_at) ||
      Math.abs(nowSeconds - event.created_at) > REGISTER_MAX_AGE_SECONDS) {
    return { status: 401, body: { ok: false, reason: 'stale' } };
  }
  // Publish only listeners the operator actually configured. In particular,
  // a turns: URL is not usable until a certificate has been installed.
  if (!urls.length || urls.some((url) => !/^turns?:[^\s]+$/.test(url))) {
    return { status: 503, body: { ok: false, reason: 'unconfigured' } };
  }
  try {
    return { status: 200, body: { ok: true,
      ...turnCredentials({ secret, ttlSeconds: 600, nowSeconds }), urls } };
  } catch {
    return { status: 503, body: { ok: false, reason: 'unconfigured' } };
  }
}

// ---------------------------------------------------------------------------
// Reports
// ---------------------------------------------------------------------------

// A report is signed the same way a TURN request is — same kind, same key,
// its own `action` tag — for the same reason: unforgeable without inventing a
// second signing scheme, and unforwardable to a different purpose because the
// purpose is inside what got signed.
const REPORT_KIND = REGISTER_KIND;

// Wider than a registration's five minutes in both directions, because a
// report is typed by a person rather than fired by a background timer: the
// sheet can sit open while they write a note, and the phone's clock is
// trusted less than the seconds it takes to submit. Still bounded, so a
// captured report can't be replayed indefinitely.
const REPORT_MAX_PAST_SECONDS = 600;
const REPORT_MAX_FUTURE_SECONDS = 60;

const REPORT_REASONS = new Set(['spam', 'abuse', 'violence', 'sexual', 'other']);
const REPORT_CONTEXTS = new Set(['direct', 'channel', 'airdrop', 'general']);
const REPORT_MESSAGE_KINDS = new Set(['text', 'photo', 'video', 'voice', 'file', 'sticker', 'other']);

const HEX64 = /^[0-9a-f]{64}$/i;

/// The report payload out of an event's `content`, or `null` when anything in
/// it is malformed — never thrown, so the caller has one thing to check.
///
/// `target` is required for `direct` (there is no other way to say who the
/// report is about) and optional everywhere else: `general` has nobody in
/// particular, and `channel`/`airdrop` reports may carry only a message.
export function parseReportPayload(content) {
  let payload;
  try {
    payload = JSON.parse(content);
  } catch {
    return null;
  }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return null;

  const { reason, note, target, targetNpub, context, channelId, message } = payload;
  if (!REPORT_REASONS.has(reason)) return null;
  if (!REPORT_CONTEXTS.has(context)) return null;
  if (context === 'direct' && typeof target !== 'string') return null;
  // Channel frames expose only the author's 8-byte signing fingerprint.
  // Requiring a full mesh identity here made every real channel report fail.
  if (target !== undefined && (typeof target !== 'string' ||
      !(context === 'channel' ? /^[0-9a-f]{16}$/i.test(target) : HEX64.test(target)))) return null;
  if (targetNpub !== undefined && (typeof targetNpub !== 'string' || !HEX64.test(targetNpub))) return null;
  if (note !== undefined && (typeof note !== 'string' || note.length > 500)) return null;
  if (channelId !== undefined && typeof channelId !== 'string') return null;

  let parsedMessage;
  if (message !== undefined) {
    if (!message || typeof message !== 'object' || Array.isArray(message)) return null;
    const { text, kind, sentAt } = message;
    if (text !== undefined && (typeof text !== 'string' || text.length > 4000)) return null;
    if (kind !== undefined && !REPORT_MESSAGE_KINDS.has(kind)) return null;
    // A safe, non-negative integer: `Number.isSafeInteger` already refuses
    // NaN, Infinity and fractions, so only the sign needs its own check.
    if (sentAt !== undefined && (!Number.isSafeInteger(sentAt) || sentAt < 0)) return null;
    parsedMessage = {
      ...(text !== undefined ? { text } : {}),
      ...(kind !== undefined ? { kind } : {}),
      ...(sentAt !== undefined ? { sentAt } : {}),
    };
  }

  return {
    reason,
    context,
    ...(note !== undefined ? { note } : {}),
    ...(target !== undefined ? { target } : {}),
    ...(targetNpub !== undefined ? { targetNpub } : {}),
    ...(channelId !== undefined ? { channelId } : {}),
    ...(parsedMessage !== undefined ? { message: parsedMessage } : {}),
  };
}

/// A sliding-window log: one array of accepted timestamps per key, plus one
/// for the whole service. Trimmed to the window on every call, so a key's or
/// the service's quota is always exactly "how many in the last hour", not a
/// count that resets on a clock boundary and can be burst around.
///
/// `/report` takes no identity beyond the signing key on the event, so a
/// caller that signs with a fresh key per request pays nothing for it —
/// every key is "new" here and, without this, would sit in `perKeyHits`
/// forever with an empty (fully expired) array. Two things bound that: an
/// empty array is deleted the moment the key that owns it is looked at
/// again, and — since a key that's never looked at again would otherwise
/// never trigger that — a full sweep runs every `sweepEvery` calls that
/// drops every key whose whole window has expired, seen or not.
export function createRateLimiter({ perKey = 10, total = 200, windowSeconds = 3600, sweepEvery = 1000 } = {}) {
  const perKeyHits = new Map();
  let totalHits = [];
  let calls = 0;

  function sweep(cutoff) {
    for (const [key, hits] of perKeyHits) {
      const kept = hits.filter((t) => t > cutoff);
      if (kept.length === 0) perKeyHits.delete(key);
      else perKeyHits.set(key, kept);
    }
  }

  return {
    // Exposed for tests, so "the map does not grow without bound" can be
    // checked directly instead of inferred from timing.
    get size() {
      return perKeyHits.size;
    },
    allow(pubkey, nowSeconds) {
      const cutoff = nowSeconds - windowSeconds;
      totalHits = totalHits.filter((t) => t > cutoff);
      const keyHits = (perKeyHits.get(pubkey) ?? []).filter((t) => t > cutoff);
      if (keyHits.length === 0) perKeyHits.delete(pubkey);
      else perKeyHits.set(pubkey, keyHits);

      calls += 1;
      if (calls % sweepEvery === 0) sweep(cutoff);

      if (keyHits.length >= perKey || totalHits.length >= total) {
        return false;
      }

      keyHits.push(nowSeconds);
      totalHits.push(nowSeconds);
      perKeyHits.set(pubkey, keyHits);
      return true;
    },
  };
}

/// The report store: an append-only log on disk (`reports.jsonl`), mirrored
/// in memory. `seq` is assigned here, monotonically, and survives a restart
/// by scanning the highest `seq` already on disk — there is no separate
/// counter file to fall out of step with the log itself.
///
/// `append` only ever grows the file. `update` (S2's ban/dismiss) can't:
/// changing one line of a JSONL file in place means rewriting it, so it goes
/// through the same temp-file-then-rename the token store uses at ~line 107
/// — a crash mid-write leaves the old file intact rather than a half-written
/// one.
export function createReportStore(path = process.env.REPORTS_PATH || './reports.jsonl') {
  let reports = null;
  let nextSeq = 1;
  let loadingPromise = null;

  function load() {
    if (reports) return Promise.resolve();
    if (!loadingPromise) {
      loadingPromise = (async () => {
        const map = new Map();
        let maxSeq = 0;
        try {
          const raw = await readFile(path, 'utf8');
          for (const line of raw.split('\n')) {
            if (!line.trim()) continue;
            try {
              const report = JSON.parse(line);
              if (report && typeof report.id === 'string') {
                map.set(report.id, report);
                if (Number.isSafeInteger(report.seq) && report.seq > maxSeq) maxSeq = report.seq;
              }
            } catch {
              // One corrupt line (a crash mid-append, before appendFile's
              // write completed) must not lose every report before it.
            }
          }
        } catch (error) {
          if (error.code !== 'ENOENT') throw error;
        }
        reports = map;
        nextSeq = maxSeq + 1;
      })();
    }
    return loadingPromise;
  }

  // Every write — append or update — goes through this queue, so an update
  // racing an append can't read the map mid-mutation or clobber a rewrite
  // with a stale one.
  let queue = Promise.resolve();
  function enqueue(task) {
    const result = queue.then(task);
    queue = result.then(() => undefined, () => undefined);
    return result;
  }

  async function rewrite() {
    const body = [...reports.values()]
      .sort((a, b) => a.seq - b.seq)
      .map((report) => JSON.stringify(report))
      .join('\n');
    const temp = `${path}.${randomUUID()}`;
    await writeFile(temp, body.length ? `${body}\n` : '');
    await rename(temp, path);
  }

  return {
    async append(report) {
      await load();
      return enqueue(async () => {
        const stored = { ...report, seq: nextSeq++ };
        reports.set(stored.id, stored);
        await appendFile(path, `${JSON.stringify(stored)}\n`);
        return stored;
      });
    },
    async update(id, patch) {
      await load();
      return enqueue(async () => {
        const existing = reports.get(id);
        if (!existing) return null;
        const updated = { ...existing, ...patch };
        reports.set(id, updated);
        await rewrite();
        return updated;
      });
    },
    // The atomic half of ban/dismiss (S2 review, round 1): reading a report's
    // status and later writing a new one, as two separate calls, lets two
    // concurrent decisions both read 'open' and both win. This does the
    // check and the write inside the *same* enqueued task, so the second of
    // two concurrent `decide` calls on one report sees the first one's write
    // — `enqueue` chains every task after the one before it, `append` and
    // `update` included, so this serializes against those too.
    //
    // Returns `{notFound: true}`, `{conflict: <current status>}`, or
    // `{report: <updated>}` — never throws for an ordinary "already decided",
    // since that is the expected outcome of a race, not a failure.
    async decide(id, patch) {
      await load();
      return enqueue(async () => {
        const existing = reports.get(id);
        if (!existing) return { notFound: true };
        if (existing.status !== 'open') return { conflict: existing.status };
        const updated = { ...existing, ...patch };
        reports.set(id, updated);
        await rewrite();
        return { report: updated };
      });
    },
    async open() {
      await load();
      return [...reports.values()]
        .filter((report) => report.status === 'open')
        .sort((a, b) => a.seq - b.seq);
    },
    // S2's admin routes look a report up by id (to check its current status
    // before ban/dismiss, and to hand the full report to `bans.ban`). `null`
    // rather than `undefined` for "no such id", so a route can test it the
    // same way `update` already reports "nothing to update".
    async get(id) {
      await load();
      return reports.get(id) ?? null;
    },
    // S2's `GET /admin/reports?since=<seq>` paging: everything appended after
    // `seq` (0 = all), in order, plus the `seq` to ask for next time.
    async since(seq) {
      await load();
      const rest = [...reports.values()]
        .filter((report) => report.seq > seq)
        .sort((a, b) => a.seq - b.seq);
      const next = rest.length ? rest[rest.length - 1].seq : seq;
      return { reports: rest, next };
    },
  };
}

const reportLimiter = createRateLimiter();
const reportStore = createReportStore();

function logReport(report) {
  log('report', `${short(report.reporter)} reported ${report.context} (${report.reason}) [${report.id}]`);
}

export async function handleReport(event, {
  nowSeconds = Math.floor(Date.now() / 1000),
  limiter,
  store,
  notify = () => {},
} = {}) {
  if (!verifyEvent(event) || event.kind !== REPORT_KIND ||
      !event.tags.some((tag) => Array.isArray(tag) && tag[0] === 'action' && tag[1] === 'report')) {
    return { status: 401, body: { ok: false, reason: 'signature' } };
  }
  if (!Number.isSafeInteger(event.created_at) ||
      event.created_at < nowSeconds - REPORT_MAX_PAST_SECONDS ||
      event.created_at > nowSeconds + REPORT_MAX_FUTURE_SECONDS) {
    return { status: 401, body: { ok: false, reason: 'stale' } };
  }
  const payload = parseReportPayload(event.content);
  if (!payload) return { status: 400, body: { ok: false, reason: 'payload' } };
  if (!limiter.allow(event.pubkey, nowSeconds)) {
    return { status: 429, body: { ok: false, reason: 'rate' } };
  }

  const report = {
    id: randomBytes(8).toString('hex'),
    at: nowSeconds,
    reporter: event.pubkey,
    status: 'open',
    ...payload,
  };
  const stored = await store.append(report);
  // The report is already durable at this point; a notifier that throws or
  // rejects (a dead Telegram bot, a network blip) is not the caller's
  // problem and must not turn an accepted, stored report into a 500.
  try {
    const outcome = notify(stored ?? report);
    if (outcome && typeof outcome.catch === 'function') {
      outcome.catch((error) => log('report', `notify failed: ${error?.message ?? error}`));
    }
  } catch (error) {
    log('report', `notify failed: ${error?.message ?? error}`);
  }
  return { status: 200, body: { ok: true, id: report.id } };
}

// ---------------------------------------------------------------------------
// Admin API (Task S2)
// ---------------------------------------------------------------------------

// The Telegram bot (`bot/`, Task S4) is a separate process on the same
// droplet. It never gets a copy of anybody's signing key, so it cannot speak
// the Nostr-event protocol `/report` and `/turn` use — it authenticates with
// a plain bearer token instead, and is trusted only because nothing but that
// same droplet can reach it (see the remoteAddress comment below).
const ADMIN_LOCAL_ADDRESSES = new Set(['127.0.0.1', '::1', '::ffff:127.0.0.1']);

/// Constant-time token comparison. `timingSafeEqual` throws on unequal
/// lengths rather than saying no, so that has to be checked first — and a
/// length mismatch is itself safe to leak, since it says nothing about which
/// bytes were right.
function timingSafeTokenEqual(provided, expected) {
  const providedBuf = Buffer.from(provided, 'utf8');
  const expectedBuf = Buffer.from(expected, 'utf8');
  if (providedBuf.length !== expectedBuf.length) return false;
  return timingSafeEqual(providedBuf, expectedBuf);
}

// ---------------------------------------------------------------------------
// The ban list (Task S3)
// ---------------------------------------------------------------------------

/// The exact bytes that get signed, and the only ones: `JSON.stringify` of
/// the four public fields with their arrays sorted, key order fixed, and no
/// `sig` inside it (a signature can't cover itself). The app verifies with
/// this same function — see `banListPublicKeyHex`/`canonicalBanBody` in
/// `lib/features/moderation/data/ban_list_controller.dart` — so a change here
/// is a wire change and breaks every phone that already trusts a list signed
/// the old way.
export function canonicalBanBody({ v, updatedAt, identities, npubs, fingerprints }) {
  return JSON.stringify({
    v,
    updatedAt,
    identities: [...identities].sort(),
    npubs: [...npubs].sort(),
    fingerprints: [...fingerprints].sort(),
  });
}

/// The signed, published ban list, plus the store behind it.
///
/// Three sets, not one, because "banned" means different things depending on
/// what the report was about (S3 spec): a direct/general/airdrop report names
/// an *identity* — the Nostr key a phone signs `/register` and `/turn` with,
/// which is also what a `report.target` carries for those contexts. A channel
/// report names a *fingerprint* — a channel post's author is known only by
/// its signing fingerprint (`Message.authorId`), never by an identity key, so
/// there is nothing else to ban. `npubs` is separate again: it exists only
/// when a report also carries `targetNpub`, and it is `npubs` — not
/// `identities` — that `/register` and `/turn` check, because those routes
/// see exactly one thing about the caller: the Nostr pubkey the request is
/// signed with. A report naming only a peer's mesh identity (`target`, no
/// `targetNpub`) still hides that peer everywhere the app itself enforces the
/// list (A6); it just can't be turned into a server-side refusal, because the
/// server was never told which registration key belongs to that peer.
///
/// Loaded synchronously at construction (`readFileSync`), not lazily: `list()`
/// has to be callable the instant this returns — `GET /banned` and the
/// `/register`/`/turn` 403 checks can't await a load on every request — so
/// there is no path where an empty, not-yet-loaded cache would be signed and
/// handed out as if it were the real list. A missing file (first run) is read
/// as "nothing banned yet", the same way `loadStore` above treats `ENOENT`.
///
/// `ban`/`unban` still go through a queue, same shape as the report store's:
/// two admin decisions arriving at once must not race a read-modify-write of
/// the in-memory sets and lose one of them.
export function createBans({
  path = process.env.BANNED_PATH || './banned.json',
  signingKeyPkcs8B64 = process.env.BAN_SIGNING_KEY,
  // A function, not a value evaluated once at construction (review round 1,
  // critical): the process-lifetime `adminBans` below is built exactly once
  // at import time, so a bare `Math.floor(Date.now() / 1000)` default would
  // freeze `updatedAt` at boot time forever — every ban and unban for the
  // life of the process would stamp the same second, and the app's "reject
  // an older `updatedAt` than the stored one" check (A6 spec) would then
  // reject every list after the first as stale-or-equal.
  nowSeconds = () => Math.floor(Date.now() / 1000),
} = {}) {
  const identities = new Set();
  const npubs = new Set();
  const fingerprints = new Set();
  let updatedAt = 0;

  let privateKey = null;
  if (signingKeyPkcs8B64) {
    try {
      privateKey = createPrivateKey({
        key: Buffer.from(signingKeyPkcs8B64, 'base64'),
        format: 'der',
        type: 'pkcs8',
      });
    } catch (error) {
      log('bans', `signing key unusable: ${error.message}`);
      privateKey = null;
    }
  }

  try {
    const raw = JSON.parse(readFileSync(path, 'utf8'));
    if (Number.isSafeInteger(raw.updatedAt)) updatedAt = raw.updatedAt;
    for (const id of raw.identities ?? []) if (typeof id === 'string') identities.add(id);
    for (const npub of raw.npubs ?? []) if (typeof npub === 'string') npubs.add(npub);
    for (const fp of raw.fingerprints ?? []) if (typeof fp === 'string') fingerprints.add(fp);
  } catch (error) {
    if (error.code !== 'ENOENT') log('bans', `load failed: ${error.message}`);
  }

  let cached;
  function rebuild() {
    const body = {
      v: 1,
      updatedAt,
      identities: [...identities].sort(),
      npubs: [...npubs].sort(),
      fingerprints: [...fingerprints].sort(),
    };
    const sig = privateKey
      ? cryptoSign(null, Buffer.from(canonicalBanBody(body), 'utf8'), privateKey).toString('hex')
      : '';
    cached = { ...body, sig };
  }
  rebuild();

  async function persist() {
    // The raw sets, not the signed body: `sig` is recomputed from them on
    // every load, so persisting it too would just be a second copy that can
    // go stale relative to the first if the two are ever written separately.
    const body = JSON.stringify({
      updatedAt,
      identities: [...identities],
      npubs: [...npubs],
      fingerprints: [...fingerprints],
    });
    const temp = `${path}.${randomUUID()}`;
    await writeFile(temp, body);
    await rename(temp, path);
  }

  // Same pattern as the report store's `enqueue` above: every mutation is
  // chained after the one before it, so two concurrent bans can't both read
  // the sets before either has written, and lose one.
  let queue = Promise.resolve();
  function enqueue(task) {
    const result = queue.then(task);
    queue = result.then(() => undefined, () => undefined);
    return result;
  }

  // Strictly increasing, never just "the clock right now" (review round 1):
  // two bans inside the same wall-clock second must still produce two
  // different `updatedAt`s, or the second one wouldn't look newer to a phone
  // that already has the first — and a clock stepped backwards (NTP
  // correction, a wrong system clock) must not let `updatedAt` go backwards
  // either, since that's exactly the "older `updatedAt` than stored" case
  // the app is told to reject. So this is `max(now(), previous + 1)`, not
  // `now()`.
  function nextUpdatedAt() {
    const now = typeof nowSeconds === 'function' ? nowSeconds() : nowSeconds;
    return Math.max(now, updatedAt + 1);
  }

  return {
    // Whether a real signature will ever come out of `list()`. `GET /banned`
    // uses this to answer 503 `unconfigured` instead of publishing a list
    // nobody can verify — the same shape as `handleTurn`'s `secret`/`urls`
    // check.
    configured: privateKey !== null,
    async ban(report) {
      return enqueue(async () => {
        // Lower-cased before insertion (review round 1, minor): every hex
        // key elsewhere in this file — `verifyEvent`'s pubkey/id/sig regexes,
        // `deviceTokenOf`'s APNs-token check — is matched and stored
        // lower-case, and `isBannedNpub`/the app's own comparisons assume
        // the same. A report signed by a client that happened to send mixed
        // case would otherwise sit in the set forever, matching nothing.
        if (report.context === 'channel') {
          if (typeof report.target === 'string') fingerprints.add(report.target.toLowerCase());
        } else if (typeof report.target === 'string') {
          identities.add(report.target.toLowerCase());
        }
        if (typeof report.targetNpub === 'string') npubs.add(report.targetNpub.toLowerCase());
        updatedAt = nextUpdatedAt();
        rebuild();
        await persist();
      });
    },
    async unban(key) {
      return enqueue(async () => {
        // Same lower-casing on the way out, so `/admin/unban` matches
        // regardless of the case the caller typed the key in.
        const lower = key.toLowerCase();
        const inIdentities = identities.delete(lower);
        const inNpubs = npubs.delete(lower);
        const inFingerprints = fingerprints.delete(lower);
        const removed = inIdentities || inNpubs || inFingerprints;
        if (removed) {
          updatedAt = nextUpdatedAt();
          rebuild();
          await persist();
        }
        return removed;
      });
    },
    // What `/register` and `/turn` check: the Nostr pubkey a request is
    // signed with, which is what a `targetNpub` names. See the block comment
    // above for why this is deliberately not `identities`. `verifyEvent`
    // already requires `event.pubkey` to match `/^[0-9a-f]{64}$/` — lower-case
    // only — so no lower-casing is needed on this side of the comparison.
    isBannedNpub(hex) {
      return npubs.has(hex);
    },
    // The cached, already-signed body. Rebuilt on every `ban`/`unban` above,
    // never per call here — signing on every `GET /banned` would be a private
    // key operation per request for a list that changes only on a decision.
    list() {
      return cached;
    },
  };
}

/// `GET /banned`, factored out of the route so it can be exercised over a
/// real HTTP server with an injected `bans` — the same "build a handler
/// instance without a key" shape `handleTurn`'s `secret`/`urls` tests already
/// use — rather than only through the module's own singleton `adminBans`
/// (review round 1: a real HTTP test for the 503 `unconfigured` case, not
/// just a check of `bans.configured`).
export function handleBanned({ bans }) {
  if (!bans.configured) {
    // Same "not usable yet" shape `/turn` answers for a missing TURN_SECRET:
    // 503, so a deployment mid-setup reads as unfinished rather than as an
    // empty, trustworthy list.
    return { status: 503, cacheControl: 'no-store', body: { ok: false, reason: 'unconfigured' } };
  }
  // Public and cacheable — this is the list every phone polls every six
  // hours (A6 spec), not an admin route. `max-age=300` bounds how stale a
  // CDN or proxy in front of Caddy could ever serve it without gating the
  // list behind the same no-store every other write-bearing route uses.
  return { status: 200, cacheControl: 'public, max-age=300', body: bans.list() };
}

const adminBans = createBans();

const ADMIN_DECISION_ROUTE = /^\/admin\/reports\/([^/]+)\/(ban|dismiss)$/;

/// The localhost-only admin API the Telegram bot talks to.
///
/// Every route needs both an `authorization: Bearer <ADMIN_TOKEN>` header
/// *and* a loopback `remoteAddress` — and refuses to say which one was wrong.
/// A mismatched token or a non-local caller both come back 404, the same 404
/// an unrelated path would get, so a scan of this server never learns that an
/// admin API exists here at all.
///
/// **Why the loopback check alone is not enough.** Caddy
/// (`push/deploy/Caddyfile`) terminates TLS and reverse-proxies every public
/// request to `127.0.0.1:8080` — the same process, the same port, this
/// handler included. From `request.socket.remoteAddress`'s point of view a
/// stranger's request over the internet and the bot's own request from this
/// droplet are *indistinguishable*: both arrive as a TCP connection from
/// 127.0.0.1. If that check were trusted alone, the bearer token would be the
/// only real gate — one leaked token and the admin API is open to the
/// internet. So it isn't trusted alone: Caddy's `reverse_proxy` always adds
/// `X-Forwarded-For` (along with `X-Forwarded-Proto`/`X-Forwarded-Host`) to
/// what it forwards, and the bot, calling :8080 directly, never sends it. A
/// request that carries one is refused here regardless of address or token,
/// which is what actually distinguishes "came in through Caddy" from "came
/// from the bot on this box". `Via` is checked too — Caddy doesn't set it by
/// default, but a proxy in front of *that* might, and refusing it costs
/// nothing a real local caller would ever trip over. See
/// `push/test/admin.test.js` for the proof, and `push/deploy/Caddyfile` for
/// the first layer: Caddy itself now 404s `/admin/*` before this code ever
/// sees the request, so this header check is defence in depth, not the only
/// thing standing in the way.
export async function handleAdmin(request, {
  adminToken = process.env.ADMIN_TOKEN,
  remoteAddress,
  store,
  bans,
  nowSeconds = Math.floor(Date.now() / 1000),
} = {}) {
  void nowSeconds; // reserved for S3-era freshness checks on ban/unban bodies
  const notFound = { status: 404, body: { ok: false } };
  if (!adminToken) return notFound;
  if (!ADMIN_LOCAL_ADDRESSES.has(remoteAddress)) return notFound;
  const headers = request?.headers ?? {};
  if (headers['x-forwarded-for'] !== undefined || headers['via'] !== undefined) {
    return notFound;
  }
  const authorization = typeof headers.authorization === 'string' ? headers.authorization : '';
  const provided = authorization.startsWith('Bearer ') ? authorization.slice('Bearer '.length) : '';
  if (!provided || !timingSafeTokenEqual(provided, adminToken)) return notFound;

  const url = new URL(request.url, 'http://admin.local');
  const method = request.method;

  if (method === 'GET' && url.pathname === '/admin/reports') {
    if (url.searchParams.get('status') === 'open') {
      return { status: 200, body: { reports: await store.open() } };
    }
    const rawSince = url.searchParams.get('since');
    let sinceSeq = 0;
    if (rawSince !== null) {
      const parsed = Number(rawSince);
      // Anything that isn't a non-negative integer — `abc`, `-1`, `1.5` — is
      // refused rather than quietly treated as "from the start": a typo in a
      // bot restart's saved `seq` should not silently resend the whole
      // history of reports.
      if (!Number.isSafeInteger(parsed) || parsed < 0) {
        return { status: 400, body: { reason: 'since' } };
      }
      sinceSeq = parsed;
    }
    const { reports, next } = await store.since(sinceSeq);
    return { status: 200, body: { reports, next } };
  }

  const decision = method === 'POST' ? url.pathname.match(ADMIN_DECISION_ROUTE) : null;
  if (decision) {
    const [, id, action] = decision;
    // `decide` does the read-check-write atomically inside the store's write
    // queue (S2 review, round 1): two concurrent decisions on one report
    // can't both observe 'open' the way a separate `get` then `update` could.
    // For a dismiss that's the whole story. For a ban, the status is flipped
    // to 'banned' *before* `bans.ban` runs — only the winner of the race gets
    // this far — and reverted through the same queue if `bans.ban` rejects,
    // so the only 200 a caller ever sees is a ban that was actually applied.
    const targetStatus = action === 'ban' ? 'banned' : 'dismissed';
    const decided = await store.decide(id, { status: targetStatus });
    if (decided.notFound) return { status: 404, body: { reason: 'no such report' } };
    if (decided.conflict) return { status: 409, body: { ok: false, status: decided.conflict } };
    if (action === 'dismiss') {
      return { status: 200, body: { ok: true, report: decided.report } };
    }
    try {
      await bans.ban(decided.report);
    } catch {
      await store.update(id, { status: 'open' });
      return { status: 503, body: { reason: 'bans unavailable' } };
    }
    return { status: 200, body: { ok: true, report: decided.report } };
  }

  if (method === 'POST' && url.pathname === '/admin/unban') {
    let payload;
    try {
      payload = JSON.parse(request.body || '{}');
    } catch {
      return { status: 400, body: { reason: 'body' } };
    }
    if (!payload || typeof payload.key !== 'string' || !payload.key) {
      return { status: 400, body: { reason: 'payload' } };
    }
    try {
      const removed = await bans.unban(payload.key);
      return { status: 200, body: { ok: removed } };
    } catch {
      return { status: 503, body: { reason: 'bans unavailable' } };
    }
  }

  return notFound;
}
