import { schnorr } from '@noble/curves/secp256k1';
import { sha256 } from '@noble/hashes/sha256';
import { bytesToHex, utf8ToBytes } from '@noble/hashes/utils';

/// Proving that a request comes from the key it spends from.
///
/// There are no accounts in cubechat and there will not be. The Nostr key is
/// the only durable identity, and `push/` already proves ownership of one the
/// same way — a signed event whose id is the hash of its canonical form.
///
/// **Copied from the doorbell rather than shared with it.** The two services
/// deploy separately, and a module in between means a wallet release can take
/// the doorbell down with it. Fifty lines of duplication is the cheaper
/// failure.
///
/// The signature covers the tags, which is what makes this safe to build an
/// operation out of: the amount and the recipient are inside what was signed,
/// so nothing on the path can change them.

export class AuthError extends Error {
  constructor(code, message) {
    super(message ?? code);
    this.name = 'AuthError';
    this.code = code;
  }
}

/// How far a request's clock may be from ours.
///
/// A signed request is a bearer token until it expires: anybody who overhears
/// one can replay it until then. Two minutes is long enough for a phone on a
/// bad train connection and short enough that a recording is worth nothing by
/// the time it is used.
export const WINDOW_SECONDS = 120;

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

function wellFormed(event) {
  return (
    typeof event?.pubkey === 'string' &&
    typeof event?.id === 'string' &&
    typeof event?.sig === 'string' &&
    typeof event?.content === 'string' &&
    typeof event?.created_at === 'number' &&
    Array.isArray(event?.tags) &&
    /^[0-9a-f]{64}$/.test(event.pubkey) &&
    /^[0-9a-f]{64}$/.test(event.id) &&
    /^[0-9a-f]{128}$/.test(event.sig)
  );
}

/// Check the event, then read the operation out of it.
///
/// Throws [AuthError] rather than returning null so a caller cannot forget to
/// look: the difference between "not authorised" and "authorised for nothing"
/// is the whole of the security here.
export function authorise(event, { now = Date.now() / 1000 } = {}) {
  if (!wellFormed(event)) throw new AuthError('malformed');

  const computed = bytesToHex(sha256(utf8ToBytes(serializeForId(event))));
  if (computed !== event.id) throw new AuthError('signature', 'id mismatch');

  let ok = false;
  try {
    ok = schnorr.verify(event.sig, event.id, event.pubkey);
  } catch {
    ok = false;
  }
  if (!ok) throw new AuthError('signature');

  if (Math.abs(now - event.created_at) > WINDOW_SECONDS) {
    throw new AuthError('stale');
  }

  const tag = (name) => {
    for (const t of event.tags) {
      if (Array.isArray(t) && t[0] === name && typeof t[1] === 'string') {
        return t[1];
      }
    }
    return null;
  };

  const op = tag('op');
  if (!op) throw new AuthError('op', 'no op tag');

  // The key that signed is the key that spends. Nothing reads an npub from a
  // request body, anywhere in this service.
  return { npub: event.pubkey, op, tag };
}
