import { randomBytes } from 'node:crypto';

import {
  CAP_DOMAIN,
  TICKET_DOMAIN,
  b64uDecode,
  b64uEncode,
  ipBucket,
  lookupOf,
  newSecret,
  registrationTranscript,
  verifyEd25519,
} from './crypto.js';
import { Coalescer, RateLimiter } from './limits.js';

export const DEFAULTS = {
  /** Ticket and capability leases. Renewed on ordinary app launches. */
  ticketLeaseMs: 90 * 24 * 3600 * 1000,
  capabilityLeaseMs: 90 * 24 * 3600 * 1000,
  /** How far a registration timestamp may be from ours. */
  registerSkewMs: 5 * 60 * 1000,
  /** Wake limits, per capability and per device. Deliberately conservative. */
  wakePerMinute: 6,
  wakePerHour: 60,
  /** Global abuse ceiling per source address bucket. */
  ipPerMinute: 60,
  coalesceMs: 3000,
  maxCapabilitiesPerTicket: 64,
  maxBodyBytes: 4096,
};

/**
 * The wake plane.
 *
 * Two halves that phase 1 co-locates but never merges: a **frontend** that
 * knows capabilities and opaque tickets, and a **gateway** that knows tickets
 * and APNs tokens. Neither can map a capability to a device on its own, which
 * is the property that survives splitting them across two operators later.
 *
 * Nothing here ever sees a message, an npub, a chat id, or a cubechat identity.
 * A wake is a doorbell: it carries one random number and means "there is mail",
 * and the app finds out what and from whom by fetching from Nostr and checking
 * the signatures it already checks.
 */
export class WakeService {
  constructor({ store, apns, config = {}, now = () => Date.now() }) {
    this._store = store;
    this._apns = apns;
    this._cfg = { ...DEFAULTS, ...config };
    this._now = now;
    this._limiter = new RateLimiter({ now });
    this._coalescer = new Coalescer({ windowMs: this._cfg.coalesceMs, now });
    // Rotated daily so yesterday's abuse counters cannot be re-linked to an
    // address, and never written anywhere.
    this._ipSalt = randomBytes(32);
    this._ipSaltDay = Math.floor(now() / 86400000);
  }

  // ------------------------------------------------------------ gateway: /v1/tickets

  /**
   * Register an APNs token and mint the bearer ticket that stands for it.
   *
   * The ticket is returned exactly once. Everything afterwards — token
   * rotation, lease renewal, deletion — is authenticated by the control key,
   * not by holding the ticket, so a leaked ticket cannot repoint a device.
   */
  registerTicket(body) {
    const controlPubkey = b64uDecode(body?.control_pubkey);
    const deviceToken = b64uDecode(body?.device_token);
    const nonce = b64uDecode(body?.nonce);
    const signature = b64uDecode(body?.signature);
    const environment = body?.environment;
    const topic = body?.topic;
    const timestamp = Number(body?.timestamp);

    if (
      body?.version !== 1 ||
      !controlPubkey ||
      controlPubkey.length !== 32 ||
      !deviceToken ||
      deviceToken.length === 0 ||
      // Apple has changed token length before; refuse only the absurd.
      deviceToken.length > 128 ||
      !nonce ||
      nonce.length !== 16 ||
      !signature ||
      (environment !== 'sandbox' && environment !== 'production') ||
      typeof topic !== 'string' ||
      topic.length === 0 ||
      topic.length > 255 ||
      !Number.isFinite(timestamp)
    ) {
      return { status: 400, body: { error: 'malformed' } };
    }

    const skew = Math.abs(this._now() - timestamp * 1000);
    if (skew > this._cfg.registerSkewMs) {
      return { status: 400, body: { error: 'stale' } };
    }

    const transcript = registrationTranscript({
      controlPubkey,
      deviceToken,
      environment,
      topic,
      timestamp,
      nonce,
    });
    if (!verifyEd25519(transcript, controlPubkey, signature)) {
      return { status: 401, body: { error: 'bad signature' } };
    }

    const ticket = newSecret();
    const ticketLookup = lookupOf(TICKET_DOMAIN, ticket);
    if (!this._store.noteNonce(ticketLookup, b64uEncode(nonce), this._cfg.registerSkewMs)) {
      return { status: 409, body: { error: 'replayed' } };
    }
    const row = this._store.putTicket({
      ticketLookup,
      controlPubkey,
      deviceToken,
      environment,
      topic,
      leaseMs: this._cfg.ticketLeaseMs,
    });

    return {
      status: 200,
      body: {
        version: 1,
        delivery_ticket: b64uEncode(ticket),
        registration_id: row.registrationId,
        expires_at: Math.floor(row.expiresAt / 1000),
      },
    };
  }

  // --------------------------------------------------- frontend: /v1/capabilities

  /**
   * Bind a capability hash to an opaque delivery ticket.
   *
   * The frontend is handed the ticket because phase 1 co-locates the two
   * halves; once split, this is where the ticket stops being meaningful to
   * anyone but the gateway.
   */
  registerCapability(body) {
    const capLookup = body?.cap_lookup;
    const deliveryTicket = b64uDecode(body?.delivery_ticket);
    const controlPubkey = b64uDecode(body?.control_pubkey);
    const expiresAt = Number(body?.expires_at);

    if (
      body?.version !== 1 ||
      typeof capLookup !== 'string' ||
      capLookup.length < 16 ||
      capLookup.length > 128 ||
      !deliveryTicket ||
      !controlPubkey ||
      controlPubkey.length !== 32 ||
      !Number.isFinite(expiresAt)
    ) {
      return { status: 400, body: { error: 'malformed' } };
    }

    const ticketLookup = lookupOf(TICKET_DOMAIN, deliveryTicket);
    const ticket = this._store.getTicket(ticketLookup);
    if (!ticket) return { status: 404, body: { error: 'unknown ticket' } };

    if (this._store.capabilityCountFor(ticketLookup) >= this._cfg.maxCapabilitiesPerTicket) {
      return { status: 429, body: { error: 'too many capabilities' } };
    }

    const capped = Math.min(
      expiresAt * 1000,
      this._now() + this._cfg.capabilityLeaseMs,
    );
    this._store.putCapability({
      capLookup,
      deliveryTicket: ticketLookup,
      controlPubkey,
      expiresAt: capped,
    });
    return {
      status: 200,
      body: { version: 1, expires_at: Math.floor(capped / 1000) },
    };
  }

  // ----------------------------------------------------------- frontend: /v1/wake

  /**
   * Ring the phone behind a capability.
   *
   * Always answers 202, whatever happened. An unknown, expired, revoked or
   * throttled capability must be indistinguishable from a delivered one, or
   * the endpoint becomes an oracle for whether a given capability exists — and
   * capabilities are the only identifiers in this system worth probing for.
   *
   * There is no signature on this call. Signing it with the sender's Nostr key
   * would hand the service exactly the identity the whole design omits.
   */
  async wake(body, { address } = {}) {
    const accepted = { status: 202, body: { version: 1 } };

    const capability = b64uDecode(body?.capability);
    if (body?.version !== 1 || !capability || capability.length !== 32) {
      return accepted;
    }

    if (!this._limiter.allow(this._ipKey(address), this._cfg.ipPerMinute, 60_000)) {
      return accepted;
    }

    const capLookup = lookupOf(CAP_DOMAIN, capability);
    const row = this._store.getCapability(capLookup);
    if (!row) return accepted;

    if (
      !this._limiter.allow(`cap:${capLookup}`, this._cfg.wakePerMinute, 60_000) ||
      !this._limiter.allow(`cap:${capLookup}`, this._cfg.wakePerHour, 3_600_000) ||
      !this._limiter.allow(`tkt:${row.deliveryTicket}`, this._cfg.wakePerMinute, 60_000) ||
      !this._limiter.allow(`tkt:${row.deliveryTicket}`, this._cfg.wakePerHour, 3_600_000)
    ) {
      return accepted;
    }

    // One ring per device per window, however many contacts wrote.
    if (!this._coalescer.shouldDeliver(row.deliveryTicket)) return accepted;

    await this.deliver({
      version: 1,
      delivery_ticket_lookup: row.deliveryTicket,
      template: 'cubechat-wake-v1',
    });
    return accepted;
  }

  // -------------------------------------------------------- gateway: /v1/deliver

  /**
   * Push a compiled template to the device behind a ticket.
   *
   * Takes the ticket *lookup* rather than the bearer ticket: the frontend
   * already resolved it, and passing the secret across the boundary would
   * hand the gateway something it has no use for. Only names a template —
   * never text — so this API cannot be turned into a phishing channel.
   */
  async deliver(body) {
    const lookup = body?.delivery_ticket_lookup;
    const template = body?.template;
    if (body?.version !== 1 || typeof lookup !== 'string' || typeof template !== 'string') {
      return { status: 400, body: { error: 'malformed' } };
    }
    const row = this._store.getTicket(lookup);
    if (!row || row.disabled) return { status: 404, body: { error: 'unknown ticket' } };

    try {
      const res = await this._apns.send({
        deviceToken: Buffer.from(row.deviceToken, 'base64').toString('hex'),
        topic: row.topic,
        environment: row.environment,
        template,
      });
      if (res.status === 410) {
        // The token is dead. Stop delivering to it; the app re-registers the
        // new one on its next launch.
        this._store.disableTicket(lookup);
      }
      return { status: 200, body: { version: 1, apns_status: res.status } };
    } catch (e) {
      // Never echo the message: it can carry the token in some failure modes.
      console.error('deliver: apns error');
      void e;
      return { status: 502, body: { error: 'upstream' } };
    }
  }

  _ipKey(address) {
    const day = Math.floor(this._now() / 86400000);
    if (day !== this._ipSaltDay) {
      this._ipSalt = randomBytes(32);
      this._ipSaltDay = day;
    }
    return `ip:${ipBucket(address, this._ipSalt)}`;
  }
}
