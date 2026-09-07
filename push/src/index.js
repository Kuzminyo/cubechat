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
/// What `/health` reports, so a deployment can be identified rather than
/// assumed. Bump it in the same commit as any change to this file.
const VERSION = '2026-09-07-wake-tag';

const RECIPIENT_TAG = 'p';

/// Set by the sender on the events a person would want to be woken for.
///
/// See `kWakeTag` in the app. Text messages and channel posts carry it; media
/// chunks, read receipts, typing notices and presence do not.
const WAKE_TAG = 'w';

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

const DEFAULT_LANG = 'en';

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

  const platform = platformOf(event);
  const token = deviceTokenOf(event.content, platform);
  if (!token) return { ok: false, reason: 'token' };
  const lang = languageOf(event);

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
async function sendFcm(npub, token) {
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
      data: { body: bodyFor(npub) },
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

async function sendPush(npub, token) {
  // Android goes to Google, everything else to Apple. The two networks share
  // nothing but this doorbell's intent, so the split is here rather than
  // threaded through the APNs code below.
  if (tokens.get(npub)?.platform === 'android') {
    return sendFcm(npub, token);
  }
  const [first, second] = hostsFor(npub);
  const attempt = await pushTo(npub, token, first);
  logAttempt(npub, token, first, attempt);
  if (attempt.status === 200) {
    rememberHost(npub, first);
    return true;
  }
  // The one error that means "right token, wrong address". Everything else is
  // final: a rejected payload or a retired token says the same thing on both
  // hosts, and trying twice would only double the log.
  if (attempt.reason === 'BadDeviceToken') {
    const retry = await pushTo(npub, token, second);
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
function bodyFor(npub) {
  const lang = tokens.get(npub)?.lang;
  return ALERT_BODY[lang] || ALERT_BODY[DEFAULT_LANG];
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
function pushTo(npub, token, host) {
  const payload = JSON.stringify({
    aps: {
      // The text itself, not a `loc-key`. That is what this sent until
      // 2026-08-31, and it never worked: `loc-key` names an entry in the
      // app's Localizable.strings, this Flutter app ships no such file
      // (its translations are .arb, compiled into Dart), and iOS falls back
      // to displaying the key. Every banner would have read
      // "PUSH_NEW_MESSAGE". Shipping the string from here needs no iOS
      // resource at all, and the language rides in the signed registration.
      alert: { body: bodyFor(npub) },
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
        'apns-topic': APNS_TOPIC,
        'apns-push-type': 'alert',
        'apns-priority': '10',
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
/// Coalescing rather than dropping, and it costs nothing real: this push says
/// "you have mail" and nothing else. Two events ten seconds apart mean one
/// doorbell either way; the app fetches everything waiting once it is awake.
const lastWake = new Map();
const WAKE_GAP_MS = 15_000;
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
  if (now - entry.at < WAKE_GAP_MS) return false;
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
    for (const tag of event.tags) {
      if (!Array.isArray(tag) || tag[0] !== RECIPIENT_TAG) continue;
      if (typeof tag[1] !== 'string') continue;
      const entry = tokens.get(tag[1]);
      if (!entry) continue;
      if (!shouldWake(tag[1])) continue;
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

const server = createServer(async (request, response) => {
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

void main();
