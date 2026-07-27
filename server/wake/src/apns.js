import { createPrivateKey, createSign } from 'node:crypto';
import http2 from 'node:http2';

import { b64uEncode } from './crypto.js';

const HOSTS = {
  production: 'https://api.push.apple.com',
  sandbox: 'https://api.sandbox.push.apple.com',
};

/** The only payload this service will ever send. */
export const TEMPLATES = {
  'cubechat-wake-v1': {
    collapseId: 'cubechat-wake-v1',
    payload: {
      aps: {
        alert: { 'title-loc-key': 'PUSH_WAKE_TITLE', 'loc-key': 'PUSH_WAKE_BODY' },
        sound: 'default',
        'content-available': 1,
        category: 'cubechat_wake',
        'thread-id': 'cubechat-wake',
      },
      cc: 'wake-v1',
    },
  },
};

/**
 * Token-based APNs provider over a long-lived HTTP/2 connection.
 *
 * Only compiled templates are sendable. There is no path by which a caller
 * supplies alert text, a badge, a URL, or any custom field: a compromised wake
 * frontend can therefore cause nuisance generic alerts for tickets it holds,
 * but cannot phish through arbitrary notification text.
 */
export class ApnsClient {
  /**
   * [signer] is swapped out in tests. Production passes a `.p8` key that must
   * live only in a secret manager — never in the repository, the frontend, the
   * database, or the client.
   */
  constructor({ keyId, teamId, privateKeyPem, now = () => Date.now(), fetchImpl = null }) {
    this._keyId = keyId;
    this._teamId = teamId;
    this._key = privateKeyPem ? createPrivateKey(privateKeyPem) : null;
    this._now = now;
    this._fetch = fetchImpl;
    this._sessions = new Map();
    this._jwt = null;
    this._jwtIssuedAt = 0;
  }

  /**
   * Apple rejects a provider token older than an hour and rate-limits
   * regenerating one more than once every twenty minutes, so it is cached and
   * refreshed in between.
   */
  _providerJwt() {
    const ageMs = this._now() - this._jwtIssuedAt;
    if (this._jwt && ageMs < 45 * 60 * 1000) return this._jwt;
    if (!this._key) throw new Error('no APNs signing key configured');
    const iat = Math.floor(this._now() / 1000);
    const header = b64uEncode(
      Buffer.from(JSON.stringify({ alg: 'ES256', kid: this._keyId }), 'utf8'),
    );
    const claims = b64uEncode(
      Buffer.from(JSON.stringify({ iss: this._teamId, iat }), 'utf8'),
    );
    const signer = createSign('SHA256');
    signer.update(`${header}.${claims}`);
    // APNs wants the raw 64-byte r||s pair, not the DER envelope OpenSSL emits.
    const sig = signer.sign({ key: this._key, dsaEncoding: 'ieee-p1363' });
    this._jwt = `${header}.${claims}.${b64uEncode(sig)}`;
    this._jwtIssuedAt = this._now();
    return this._jwt;
  }

  _session(environment) {
    const host = HOSTS[environment] ?? HOSTS.production;
    let s = this._sessions.get(host);
    if (s && !s.closed && !s.destroyed) return s;
    s = http2.connect(host);
    s.on('error', () => this._sessions.delete(host));
    s.on('close', () => this._sessions.delete(host));
    this._sessions.set(host, s);
    return s;
  }

  /**
   * Deliver a compiled template. Resolves `{status, reason}` — `410` means the
   * token is dead and the caller must stop using it.
   */
  async send({ deviceToken, topic, environment, template }) {
    const compiled = TEMPLATES[template];
    if (!compiled) throw new Error(`unknown template ${template}`);

    const headers = {
      ':method': 'POST',
      ':path': `/3/device/${deviceToken}`,
      authorization: `bearer ${this._providerJwt()}`,
      'apns-topic': topic,
      'apns-push-type': 'alert',
      'apns-priority': '10',
      'apns-expiration': String(Math.floor(this._now() / 1000) + 3600),
      'apns-collapse-id': compiled.collapseId,
    };
    const body = JSON.stringify(compiled.payload);

    if (this._fetch) return this._fetch({ headers, body, environment });

    return new Promise((resolve, reject) => {
      let session;
      try {
        session = this._session(environment);
      } catch (e) {
        reject(e);
        return;
      }
      const req = session.request(headers);
      let status = 0;
      let raw = '';
      req.on('response', (h) => {
        status = h[':status'];
      });
      req.on('data', (c) => {
        raw += c;
      });
      req.on('error', reject);
      req.on('end', () => {
        let reason = '';
        try {
          reason = raw ? (JSON.parse(raw).reason ?? '') : '';
        } catch {
          reason = '';
        }
        resolve({ status, reason });
      });
      req.end(body);
    });
  }

  close() {
    for (const s of this._sessions.values()) s.close();
    this._sessions.clear();
  }
}
