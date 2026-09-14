// Probe candidate relays for the location lane: NIP-11 limits, then a kind
// 1059 publish from a throwaway key and a REQ that must return it without AUTH.
// Run from push/: node tool/probe_geo_relays.mjs [rounds] [host...]
import {createHash, randomBytes} from 'node:crypto';
import {schnorr} from '@noble/curves/secp256k1';

const args = process.argv.slice(2);
const rounds = Number.parseInt(args[0] ?? '3', 10) || 3;
const hosts = args.slice(1);

const hex = (b) => Buffer.from(b).toString('hex');

function signed(key, recipient) {
  const event = {
    pubkey: hex(schnorr.getPublicKey(key)),
    created_at: Math.floor(Date.now() / 1000),
    kind: 1059,
    tags: [['p', recipient]],
    content: randomBytes(96).toString('base64'),
  };
  event.id = createHash('sha256')
    .update(JSON.stringify([0, event.pubkey, event.created_at, event.kind, event.tags, event.content]))
    .digest('hex');
  event.sig = hex(schnorr.sign(event.id, key));
  return event;
}

async function nip11(host) {
  try {
    const r = await fetch(`https://${host}/`, {
      headers: {accept: 'application/nostr+json'},
      signal: AbortSignal.timeout(6000),
    });
    const j = await r.json();
    const l = j.limitation ?? {};
    return `auth=${!!l.auth_required} pay=${!!l.payment_required} restricted=${!!l.restricted_writes}`;
  } catch (e) {
    return `nip11 ${e.name}`;
  }
}

function round(host) {
  return new Promise((resolve) => {
    const started = Date.now();
    const key = randomBytes(32);
    const recipient = hex(schnorr.getPublicKey(randomBytes(32)));
    const event = signed(key, recipient);
    let ok = null;
    let got = false;
    let ws;
    const done = (verdict) => {
      clearTimeout(timer);
      try { ws.close(); } catch {}
      resolve({verdict, ms: Date.now() - started});
    };
    const timer = setTimeout(() => done(ok === null ? 'timeout(no OK)' : `timeout(ok=${ok},got=${got})`), 8000);
    try {
      ws = new WebSocket(`wss://${host}`);
    } catch (e) {
      return done(`ctor ${e.message}`);
    }
    ws.onerror = () => done('ws error');
    ws.onopen = () => ws.send(JSON.stringify(['EVENT', event]));
    ws.onmessage = (m) => {
      let msg;
      try { msg = JSON.parse(m.data); } catch { return; }
      if (msg[0] === 'OK' && msg[1] === event.id) {
        ok = msg[2];
        if (!ok) return done(`refused: ${msg[3]}`);
        ws.send(JSON.stringify(['REQ', 'p', {kinds: [1059], '#p': [recipient], limit: 5}]));
      } else if (msg[0] === 'EVENT' && msg[2]?.id === event.id) {
        got = true;
      } else if (msg[0] === 'EOSE') {
        done(got ? 'ok' : 'stored? not returned');
      } else if (msg[0] === 'CLOSED') {
        done(`closed: ${msg[2]}`);
      } else if (msg[0] === 'AUTH') {
        // Counted as a failure: the lane must not depend on a challenge.
        done('auth challenge');
      }
    };
  });
}

for (const host of hosts) {
  const info = await nip11(host);
  const results = [];
  for (let i = 0; i < rounds; i++) {
    results.push(await round(host));
    await new Promise((r) => setTimeout(r, 1500));
  }
  const good = results.filter((r) => r.verdict === 'ok');
  const median = good.map((r) => r.ms).sort((a, b) => a - b)[Math.floor(good.length / 2)];
  console.log(`${host.padEnd(30)} ${good.length}/${rounds} ok  median ${median ?? '-'} ms  ${info}  ${[...new Set(results.map((r) => r.verdict))].join(' | ')}`);
}
