import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

/**
 * Two tables, deliberately kept apart even though phase 1 runs them in one
 * process.
 *
 * - The **gateway** table maps `ticket_lookup -> APNs token`. It is the only
 *   place a device token exists.
 * - The **frontend** table maps `cap_lookup -> delivery ticket`. It never sees
 *   a token, an npub, or a cubechat identity.
 *
 * Neither table stores the bearer secret used to look its row up: a dump of
 * either gives an attacker no way to ring anyone, because the secret is
 * pre-image-resistant from its hash.
 *
 * Storage is a JSON file rewritten atomically. That is the right size for
 * phase 1 — a single co-located process — and the interface is narrow enough
 * that swapping in a database later touches only this file.
 */
export class Store {
  constructor({ path = null, now = () => Date.now() } = {}) {
    this._path = path;
    this._now = now;
    this._tickets = new Map(); // ticket_lookup -> ticket row
    this._caps = new Map(); // cap_lookup -> capability row
    if (path) this._load();
  }

  // ------------------------------------------------------------- gateway side

  /**
   * Record (or replace) the APNs token behind a ticket.
   *
   * `registrationId` lets a client tell "my ticket still works" from "the
   * server forgot me" without presenting the ticket itself.
   */
  putTicket({ ticketLookup, controlPubkey, deviceToken, environment, topic, leaseMs }) {
    const row = {
      controlPubkey: controlPubkey.toString('base64'),
      deviceToken: deviceToken.toString('base64'),
      environment,
      topic,
      registrationId: ticketLookup.slice(0, 16),
      expiresAt: this._now() + leaseMs,
      disabled: false,
      lastSeenNonces: [],
    };
    this._tickets.set(ticketLookup, row);
    this._persist();
    return row;
  }

  getTicket(ticketLookup) {
    const row = this._tickets.get(ticketLookup);
    if (!row) return null;
    if (row.expiresAt <= this._now()) {
      this._tickets.delete(ticketLookup);
      this._persist();
      return null;
    }
    return row;
  }

  /**
   * Called on an APNs `410 Unregistered`: the token is dead, so the row must
   * stop being delivered to. Kept rather than deleted so a client presenting
   * the same ticket can re-register the new token against it.
   */
  disableTicket(ticketLookup) {
    const row = this._tickets.get(ticketLookup);
    if (!row) return;
    row.disabled = true;
    this._persist();
  }

  deleteTicket(ticketLookup) {
    this._tickets.delete(ticketLookup);
    this._persist();
  }

  /**
   * Reject a replayed registration. A nonce is remembered per ticket only for
   * as long as the timestamp window it was valid in.
   */
  noteNonce(ticketLookup, nonce, windowMs) {
    const row = this._tickets.get(ticketLookup);
    if (!row) return true;
    const cutoff = this._now() - windowMs;
    row.lastSeenNonces = row.lastSeenNonces.filter((n) => n.at > cutoff);
    if (row.lastSeenNonces.some((n) => n.nonce === nonce)) return false;
    row.lastSeenNonces.push({ nonce, at: this._now() });
    this._persist();
    return true;
  }

  // ------------------------------------------------------------ frontend side

  putCapability({ capLookup, deliveryTicket, controlPubkey, expiresAt }) {
    this._caps.set(capLookup, {
      deliveryTicket,
      controlPubkey: controlPubkey.toString('base64'),
      expiresAt,
    });
    this._persist();
  }

  getCapability(capLookup) {
    const row = this._caps.get(capLookup);
    if (!row) return null;
    if (row.expiresAt <= this._now()) {
      this._caps.delete(capLookup);
      this._persist();
      return null;
    }
    return row;
  }

  revokeCapability(capLookup) {
    this._caps.delete(capLookup);
    this._persist();
  }

  /** Count of live capabilities pointing at a ticket, for the per-device cap. */
  capabilityCountFor(deliveryTicket) {
    let n = 0;
    for (const row of this._caps.values()) {
      if (row.deliveryTicket === deliveryTicket && row.expiresAt > this._now()) n++;
    }
    return n;
  }

  /** Drop everything past its lease. Called on a timer by the server. */
  sweep() {
    const now = this._now();
    let removed = 0;
    for (const [k, v] of this._tickets) {
      if (v.expiresAt <= now) {
        this._tickets.delete(k);
        removed++;
      }
    }
    for (const [k, v] of this._caps) {
      if (v.expiresAt <= now) {
        this._caps.delete(k);
        removed++;
      }
    }
    if (removed) this._persist();
    return removed;
  }

  get size() {
    return { tickets: this._tickets.size, capabilities: this._caps.size };
  }

  // ------------------------------------------------------------- persistence

  _load() {
    try {
      const raw = JSON.parse(readFileSync(this._path, 'utf8'));
      for (const [k, v] of Object.entries(raw.tickets ?? {})) this._tickets.set(k, v);
      for (const [k, v] of Object.entries(raw.capabilities ?? {})) this._caps.set(k, v);
    } catch {
      // No file yet, or an unreadable one. Starting empty is correct: every
      // client re-registers on its next launch, and leases expire anyway.
    }
  }

  _persist() {
    if (!this._path) return;
    const payload = JSON.stringify({
      tickets: Object.fromEntries(this._tickets),
      capabilities: Object.fromEntries(this._caps),
    });
    try {
      mkdirSync(dirname(this._path), { recursive: true });
      // Write-then-rename, so a crash mid-write cannot truncate the live file.
      const tmp = `${this._path}.tmp`;
      writeFileSync(tmp, payload, { mode: 0o600 });
      renameSync(tmp, this._path);
    } catch (e) {
      console.error('store: persist failed', e.message);
    }
  }
}
