// https://id.cubechat.tech — Cube ID's only door. See
// docs/superpowers/specs/2026-09-29-cube-id-names-design.md.

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { timingSafeEqual } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { parseCard } from './card.js';
import { POW_BITS, difficulty, verifyEvent } from './events.js';
import { normalizeName } from './names.js';
import { openRegistry } from './registry.js';

/// What /health reports. Bump it in the same commit as any change here.
export const VERSION = '2026-09-29-names';

function limiter(max, windowMs, now) {
  const hits = new Map();
  return (key) => {
    const t = now();
    const list = (hits.get(key) ?? []).filter((x) => x > t - windowMs);
    if (list.length >= max) {
      hits.set(key, list);
      return false;
    }
    list.push(t);
    hits.set(key, list);
    if (hits.size > 50_000) {
      for (const [k, v] of hits) if (!v.some((x) => x > t - windowMs)) hits.delete(k);
    }
    return true;
  };
}

function send(res, status, body, headers = {}) {
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', ...headers });
  res.end(JSON.stringify(body));
}

function readBody(req, limit = 16 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) {
        reject(new Error('too-large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

const loopback = (addr) => addr === '127.0.0.1' || addr === '::1' || addr === '::ffff:127.0.0.1';

// Behind Caddy every request comes from loopback, so the real client is the
// first X-Forwarded-For entry; from anywhere else the header is not trusted.
function clientIp(req) {
  const peer = req.socket.remoteAddress ?? '';
  if (loopback(peer)) {
    const fwd = String(req.headers['x-forwarded-for'] ?? '').split(',')[0].trim();
    if (fwd) return fwd;
  }
  return peer;
}

function tokenOk(header, expected) {
  if (!expected) return false;
  const given = Buffer.from(String(header ?? '').replace(/^Bearer /, ''));
  const want = Buffer.from(expected);
  return given.length === want.length && timingSafeEqual(given, want);
}

export function createIdServer({ registry, adminToken, bannedPath, now = () => Date.now() }) {
  const opsByIp = limiter(5, 3_600_000, now);
  const opsByKey = limiter(5, 3_600_000, now);
  const lookupsByIp = limiter(60, 60_000, now);

  const server = createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const ip = clientIp(req);
    try {
      if (req.method === 'GET' && url.pathname === '/health') {
        return send(res, 200, { ok: true, version: VERSION, names: registry.count() });
      }
      if (req.method === 'GET' && url.pathname === '/.well-known/nostr.json') {
        // NIP-05. Other Nostr clients (and Cube ID sign-in later) resolve
        // dima@id.cubechat.tech through this; it must allow any origin.
        const found = registry.lookup(normalizeName(url.searchParams.get('name') ?? ''));
        const names = found ? { [found.name]: parseCard(found.card).nostrHex } : {};
        return send(res, 200, { names }, { 'access-control-allow-origin': '*' });
      }
      const card = url.pathname.match(/^\/v1\/card\/([^/]+)$/);
      if (req.method === 'GET' && card) {
        if (!lookupsByIp(ip)) return send(res, 429, { error: 'rate' });
        const found = registry.lookup(decodeURIComponent(card[1]));
        if (!found) return send(res, 404, { error: 'not-found' });
        return send(res, 200, {
          name: found.name,
          card: Buffer.from(found.card).toString('base64url'),
          reach: found.reach,
        });
      }
      const avail = url.pathname.match(/^\/v1\/available\/([^/]+)$/);
      if (req.method === 'GET' && avail) {
        if (!lookupsByIp(ip)) return send(res, 429, { error: 'rate' });
        return send(res, 200, registry.availability(decodeURIComponent(avail[1])));
      }
      if (req.method === 'POST' && url.pathname === '/v1/op') {
        let event;
        try {
          event = JSON.parse(await readBody(req));
        } catch {
          return send(res, 400, { error: 'bad-request' });
        }
        let op = '';
        try {
          op = JSON.parse(event?.content ?? '{}')?.op ?? '';
        } catch {
          // apply() reports the malformed content.
        }
        if (op === 'claim' || op === 'rename') {
          if (!opsByIp(ip)) return send(res, 429, { error: 'rate' });
          // Counted against the key only once the event is provably from that
          // key and paid its work: a key is public (it is in the card), and
          // counting junk that merely names it would let anyone lock its
          // owner out of renaming for an hour, over and over.
          if (verifyEvent(event) && difficulty(event.id) >= POW_BITS &&
              !opsByKey(event.pubkey)) {
            return send(res, 429, { error: 'rate' });
          }
        }
        const result = registry.apply(event);
        return send(res, result.status, result.body);
      }
      if (req.method === 'POST' && url.pathname === '/admin/revoke') {
        if (!loopback(req.socket.remoteAddress ?? '') || !tokenOk(req.headers.authorization, adminToken)) {
          return send(res, 403, { error: 'forbidden' });
        }
        const body = JSON.parse((await readBody(req)) || '{}');
        return send(res, 200, { revoked: registry.revoke(body) });
      }
      return send(res, 404, { error: 'not-found' });
    } catch (e) {
      console.error('[id] request failed', e);
      return send(res, 500, { error: 'internal' });
    }
  });

  // Push's ban list: a key the moderator banned loses its name too.
  server.reloadBans = async () => {
    if (!bannedPath) return 0;
    try {
      const parsed = JSON.parse(await readFile(bannedPath, 'utf8'));
      const npubs = new Set((parsed.npubs ?? []).map((x) => String(x).toLowerCase()));
      registry.setBanned(npubs);
      const n = registry.revokeNpubs(npubs);
      if (n) console.log(`[id] revoked ${n} name(s) of banned keys`);
      return n;
    } catch {
      return 0;
    }
  };
  return server;
}

async function main() {
  const registry = openRegistry({ path: process.env.DB_PATH || './names.db' });
  const server = createIdServer({
    registry,
    adminToken: process.env.ADMIN_TOKEN || '',
    bannedPath: process.env.BANNED_PATH || '/opt/cubechat-push/banned.json',
  });
  await server.reloadBans();
  setInterval(() => void server.reloadBans(), 60_000).unref();
  setInterval(() => {
    const swept = registry.sweep();
    if (swept.expired || swept.unheld) console.log('[id] sweep', swept);
  }, 3_600_000).unref();
  const port = Number(process.env.PORT || 8090);
  server.listen(port, '127.0.0.1', () =>
    console.log(`[id] ${VERSION} on 127.0.0.1:${port}, ${registry.count()} names`));
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) void main();
