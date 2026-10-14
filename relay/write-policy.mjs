#!/usr/bin/node
// strfry write policy for cubechat's relays: what may be stored here at all.
//
// Until 2026-10-14 the policy was `plugin = ""` — any key, any kind, 128 KB an
// event, no rate, kept for one to two weeks, on a droplet with ~21 GB free. Reads
// of kind 1059 were already behind NIP-42 AUTH; writes were open to anybody who
// could reach the socket, so filling the disk took a script and an afternoon,
// and a full LMDB takes the text lane down with the media one.
//
// Three rules, cheapest first:
//   1. Only kind 1059. It is the one kind the app publishes to a relay
//      (`kCubechatFrameKind`); 24242/24243 go to the HTTP servers and 22242 is
//      an AUTH message, which never reaches a write policy.
//   2. Per source address: events a minute and bytes an hour. Sized for a real
//      transfer — a 115 MB video is ~1800 chunks of ~87 KB on the wire, a few
//      minutes of sending — with room for a carrier NAT that puts many phones
//      behind one address.
//   3. Free disk. Below the floor every write is refused. A relay that says no
//      is a slower transfer; a relay whose database is full is an outage.
//
// Events strfry replays itself (import, sync, stream) are trusted: they are
// the operator's, not a stranger's.
//
// Protocol: one JSON request per line on stdin, one JSON answer per line on
// stdout — https://github.com/hoytech/strfry/blob/master/docs/plugins.md

import { statfsSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';

const ALLOWED_KINDS = new Set([1059]);

export const defaults = {
  eventsPerMinute: Number(process.env.EVENTS_PER_IP_MINUTE || 3000),
  bytesPerHour: Number(process.env.BYTES_PER_IP_HOUR || 1024 ** 3),
  minFreeBytes: Number(process.env.MIN_FREE_BYTES || 3 * 1024 ** 3),
  dbPath: process.env.DB_PATH || '.',
};

const MINUTE_MS = 60_000;
const HOUR_MS = 3_600_000;

/// Decides one request. Pure apart from `state`, which it updates, and
/// `freeBytes`, which it is handed — so the test can drive it.
export function decide(request, state, { now, freeBytes, limits = defaults }) {
  const event = request?.event;
  const id = typeof event?.id === 'string' ? event.id : '';
  const answer = (action, msg) => (msg ? { id, action, msg } : { id, action });

  if (request?.type !== 'new' || !event) return answer('reject', 'invalid: not a new event');
  if (request.sourceType !== 'IP4' && request.sourceType !== 'IP6') return answer('accept');

  if (!ALLOWED_KINDS.has(event.kind)) {
    return answer('reject', 'blocked: this relay only carries cubechat frames');
  }
  if (freeBytes < limits.minFreeBytes) {
    return answer('reject', 'error: relay storage is full, try again later');
  }

  const ip = String(request.sourceInfo || 'unknown');
  const size = Buffer.byteLength(JSON.stringify(event));
  let entry = state.get(ip);
  if (!entry) {
    entry = { minuteAt: now, events: 0, hourAt: now, bytes: 0 };
    state.set(ip, entry);
  }
  if (now - entry.minuteAt >= MINUTE_MS) {
    entry.minuteAt = now;
    entry.events = 0;
  }
  if (now - entry.hourAt >= HOUR_MS) {
    entry.hourAt = now;
    entry.bytes = 0;
  }
  if (entry.events + 1 > limits.eventsPerMinute || entry.bytes + size > limits.bytesPerHour) {
    return answer('reject', 'rate-limited: slow down');
  }
  entry.events += 1;
  entry.bytes += size;

  // Bounded, because this runs as long as strfry does: an address whose hour
  // is over carries nothing worth keeping.
  if (state.size > 50_000) {
    for (const [key, value] of state) {
      if (now - value.hourAt >= HOUR_MS) state.delete(key);
    }
  }
  return answer('accept');
}

function main() {
  const state = new Map();
  let free = Infinity;
  let freeAt = 0;
  // Once every five seconds at most: a statfs per chunk of a burst is a
  // syscall the answer does not need.
  const freeBytes = (now) => {
    if (now - freeAt >= 5000) {
      freeAt = now;
      try {
        const s = statfsSync(defaults.dbPath);
        free = s.bavail * s.bsize;
      } catch {
        // Unknown is not full. The first rule that would refuse everything on
        // a stat error is the rule that takes the relay down by accident.
        free = Infinity;
      }
    }
    return free;
  };
  const lines = createInterface({ input: process.stdin, terminal: false });
  lines.on('line', (line) => {
    let request;
    try {
      request = JSON.parse(line);
    } catch {
      return;
    }
    const now = Date.now();
    process.stdout.write(`${JSON.stringify(decide(request, state, { now, freeBytes: freeBytes(now) }))}\n`);
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
