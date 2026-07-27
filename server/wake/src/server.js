import { createServer } from 'node:http';

import { ApnsClient } from './apns.js';
import { DEFAULTS, WakeService } from './service.js';
import { Store } from './store.js';

/**
 * HTTP wiring. Everything interesting is in [WakeService]; this only reads
 * bodies, routes, and makes sure nothing sensitive reaches a log.
 *
 * Request bodies and authorization headers are never logged — a body here is a
 * bearer capability or an APNs token, and an access log is the last place
 * either should end up.
 */
export function createWakeServer({ service, maxBodyBytes = DEFAULTS.maxBodyBytes }) {
  return createServer(async (req, res) => {
    const send = (status, body) => {
      const payload = JSON.stringify(body ?? {});
      res.writeHead(status, {
        'content-type': 'application/json',
        'cache-control': 'no-store',
        'content-length': Buffer.byteLength(payload),
      });
      res.end(payload);
    };

    if (req.method !== 'POST') return send(405, { error: 'method' });

    let raw = '';
    let tooBig = false;
    req.on('data', (chunk) => {
      if (tooBig) return;
      raw += chunk;
      if (raw.length > maxBodyBytes) {
        tooBig = true;
        send(413, { error: 'too large' });
        req.destroy();
      }
    });

    req.on('end', async () => {
      if (tooBig) return;
      let body;
      try {
        body = JSON.parse(raw || '{}');
      } catch {
        return send(400, { error: 'malformed' });
      }

      const address = req.socket.remoteAddress;
      try {
        switch (req.url) {
          case '/v1/tickets': {
            const r = service.registerTicket(body);
            return send(r.status, r.body);
          }
          case '/v1/capabilities': {
            const r = service.registerCapability(body);
            return send(r.status, r.body);
          }
          case '/v1/wake': {
            const r = await service.wake(body, { address });
            return send(r.status, r.body);
          }
          case '/v1/deliver': {
            const r = await service.deliver(body);
            return send(r.status, r.body);
          }
          default:
            return send(404, { error: 'no route' });
        }
      } catch (e) {
        // Log the route, never the body.
        console.error(`error handling ${req.url}`);
        void e;
        return send(500, { error: 'internal' });
      }
    });
  });
}

/** Entry point for `npm start`. */
export function main() {
  const port = Number(process.env.PORT ?? 8080);
  const store = new Store({ path: process.env.WAKE_STORE ?? './data/wake.json' });
  const apns = new ApnsClient({
    keyId: process.env.APNS_KEY_ID,
    teamId: process.env.APNS_TEAM_ID,
    // The .p8 belongs in a secret manager, mounted at run time. It must never
    // be committed, and never reaches the frontend half of this service.
    privateKeyPem: process.env.APNS_KEY_PEM,
  });
  const service = new WakeService({ store, apns });

  // Leases expire on their own; this only reclaims the memory.
  setInterval(() => store.sweep(), 3600_000).unref();

  createWakeServer({ service }).listen(port, () => {
    console.log(`wake service listening on :${port}`);
  });
}

if (process.argv[1] && import.meta.url.endsWith(process.argv[1].replace(/\\/g, '/'))) {
  main();
}
