// Cube ID's whole state: which name points at which signed card.
//
// Every change arrives as a Nostr event signed by the owner, and the card must
// carry that same Nostr key — so the database can be restored from a backup and
// any forged row is visible, because it would not verify.

import { DatabaseSync } from 'node:sqlite';
import { parseCard } from './card.js';
import { MAX_FUTURE, MAX_PAST, POW_BITS, difficulty, verifyEvent } from './events.js';
import { nameProblem, normalizeName } from './names.js';

const DAY = 86_400;
/// After a rename the old name keeps pointing at its owner this long, so
/// nobody can take it and receive messages meant for them.
export const HOLD_SECONDS = 30 * DAY;
/// A name nobody renewed for six months belongs to a lost key; it goes free.
export const EXPIRE_SECONDS = 182 * DAY;
const REACH = new Set(['all', 'request', 'none']);
const OPS = new Set(['claim', 'rename', 'update', 'renew', 'release']);

const fail = (status, error) => ({ status, body: { error } });
const ok = (body = { ok: true }) => ({ status: 200, body });

export function openRegistry({ path = ':memory:', now = () => Date.now() } = {}) {
  const db = new DatabaseSync(path);
  db.exec(`
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS names (
      name TEXT PRIMARY KEY, nostr_pub TEXT NOT NULL UNIQUE, card BLOB NOT NULL,
      reach TEXT NOT NULL DEFAULT 'all', created_at INTEGER NOT NULL, renewed_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS held (
      name TEXT PRIMARY KEY, nostr_pub TEXT NOT NULL, until INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS revoked (
      name TEXT PRIMARY KEY, reason TEXT, at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS seen (
      id TEXT PRIMARY KEY, at INTEGER NOT NULL);
  `);
  const seconds = () => Math.floor(now() / 1000);
  const q = {
    byName: db.prepare('SELECT * FROM names WHERE name = ?'),
    byPub: db.prepare('SELECT * FROM names WHERE nostr_pub = ?'),
    held: db.prepare('SELECT * FROM held WHERE name = ?'),
    revoked: db.prepare('SELECT 1 FROM revoked WHERE name = ?'),
    revoke: db.prepare('INSERT OR REPLACE INTO revoked (name, reason, at) VALUES (?, ?, ?)'),
    seen: db.prepare('SELECT 1 FROM seen WHERE id = ?'),
    remember: db.prepare('INSERT INTO seen (id, at) VALUES (?, ?)'),
    insert: db.prepare('INSERT INTO names (name, nostr_pub, card, reach, created_at, renewed_at) VALUES (?, ?, ?, ?, ?, ?)'),
    del: db.prepare('DELETE FROM names WHERE nostr_pub = ?'),
    hold: db.prepare('INSERT OR REPLACE INTO held (name, nostr_pub, until) VALUES (?, ?, ?)'),
    unholdOwn: db.prepare('DELETE FROM held WHERE nostr_pub = ?'),
    update: db.prepare('UPDATE names SET card = ?, reach = ? WHERE nostr_pub = ?'),
    renew: db.prepare('UPDATE names SET renewed_at = ? WHERE nostr_pub = ?'),
  };

  function blocked(name, pub) {
    const problem = nameProblem(name);
    if (problem) return problem;
    if (q.revoked.get(name)) return 'reserved';
    const owner = q.byName.get(name);
    if (owner && owner.nostr_pub !== pub) return 'taken';
    const held = q.held.get(name);
    if (held && held.nostr_pub !== pub && held.until > seconds()) return 'taken';
    return null;
  }

  function verifiedCard(content, pub) {
    let card;
    try {
      card = new Uint8Array(Buffer.from(String(content.card ?? ''), 'base64url'));
      if (parseCard(card).nostrHex !== pub) return { error: fail(403, 'card-mismatch') };
    } catch {
      return { error: fail(403, 'card-invalid') };
    }
    return { card };
  }

  function apply(event) {
    if (!verifyEvent(event)) return fail(401, 'bad-signature');
    const t = seconds();
    if (event.created_at < t - MAX_PAST || event.created_at > t + MAX_FUTURE) return fail(401, 'stale');
    if (q.seen.get(event.id)) return fail(401, 'stale');
    let content;
    try {
      content = JSON.parse(event.content);
    } catch {
      return fail(400, 'bad-request');
    }
    if (!OPS.has(content?.op)) return fail(400, 'bad-request');
    const pub = event.pubkey;
    const mine = q.byPub.get(pub);
    const op = content.op;

    if ((op === 'claim' || op === 'rename') && difficulty(event.id) < POW_BITS) return fail(403, 'pow');
    if (op !== 'claim' && !mine) return fail(404, 'no-name');
    if (op === 'claim' && mine) return fail(409, 'has-name');

    let result;
    if (op === 'claim' || op === 'rename') {
      const name = normalizeName(content.name);
      const why = blocked(name, pub);
      if (why) return fail(409, why);
      const { card, error } = verifiedCard(content, pub);
      if (error) return error;
      db.exec('BEGIN');
      try {
        if (mine) {
          q.del.run(pub);
          if (mine.name !== name) q.hold.run(mine.name, pub, t + HOLD_SECONDS);
        }
        q.insert.run(name, pub, card, mine?.reach ?? 'all', mine?.created_at ?? t, t);
        db.exec('COMMIT');
      } catch (e) {
        db.exec('ROLLBACK');
        throw e;
      }
      result = ok({ name });
    } else if (op === 'update') {
      const reach = content.reach ?? mine.reach;
      if (!REACH.has(reach)) return fail(400, 'bad-request');
      const { card, error } = content.card ? verifiedCard(content, pub) : { card: mine.card };
      if (error) return error;
      q.update.run(card, reach, pub);
      result = ok({ name: mine.name });
    } else if (op === 'renew') {
      q.renew.run(t, pub);
      result = ok({ name: mine.name });
    } else {
      q.del.run(pub);
      q.unholdOwn.run(pub);
      result = ok();
    }
    q.remember.run(event.id, t);
    return result;
  }

  function lookup(raw) {
    const name = normalizeName(raw);
    if (nameProblem(name) === 'invalid' || q.revoked.get(name)) return null;
    let row = q.byName.get(name);
    if (!row) {
      const held = q.held.get(name);
      if (held && held.until > seconds()) row = q.byPub.get(held.nostr_pub);
    }
    if (!row || row.reach === 'none') return null;
    return { name, card: new Uint8Array(row.card), reach: row.reach };
  }

  function availability(raw) {
    const name = normalizeName(raw);
    const problem = nameProblem(name);
    if (problem) return { available: false, reason: problem };
    if (q.revoked.get(name)) return { available: false, reason: 'reserved' };
    if (q.byName.get(name)) return { available: false, reason: 'taken' };
    const held = q.held.get(name);
    if (held && held.until > seconds()) return { available: false, reason: 'taken' };
    return { available: true };
  }

  function revoke({ name, npub, reason = '' }) {
    const row = name ? q.byName.get(normalizeName(name)) : q.byPub.get(String(npub ?? '').toLowerCase());
    if (row) {
      q.del.run(row.nostr_pub);
      q.revoke.run(row.name, reason, seconds());
      return 1;
    }
    // A name can be revoked before anybody takes it, to keep it from ever
    // being handed out.
    if (name) q.revoke.run(normalizeName(name), reason, seconds());
    return 0;
  }

  function revokeNpubs(npubs) {
    let n = 0;
    for (const npub of npubs) n += revoke({ npub, reason: 'banned' });
    return n;
  }

  function sweep() {
    const t = seconds();
    const expired = db.prepare('DELETE FROM names WHERE renewed_at < ?').run(t - EXPIRE_SECONDS).changes;
    const unheld = db.prepare('DELETE FROM held WHERE until <= ?').run(t).changes;
    db.prepare('DELETE FROM seen WHERE at < ?').run(t - MAX_PAST - MAX_FUTURE);
    return { expired: Number(expired), unheld: Number(unheld) };
  }

  return {
    apply, lookup, availability, revoke, revokeNpubs, sweep,
    count: () => Number(db.prepare('SELECT COUNT(*) AS n FROM names').get().n),
    close: () => db.close(),
  };
}
