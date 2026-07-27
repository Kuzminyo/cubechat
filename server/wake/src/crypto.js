import { createHash, createPublicKey, randomBytes, verify } from 'node:crypto';

/** Domain-separated lookup for a delivery ticket. */
export const TICKET_DOMAIN = 'cubechat/apns-ticket/v1';
/** Domain-separated lookup for a wake capability. */
export const CAP_DOMAIN = 'cubechat/wake-cap/v1';
/** Transcript prefix for ticket registration, NUL-terminated. */
export const REGISTER_DOMAIN = 'cubechat/apns-ticket-register/v1\0';

export function b64uDecode(s) {
  if (typeof s !== 'string' || s.length === 0) return null;
  // Tolerate both alphabets and missing padding.
  const normalised = s.replace(/-/g, '+').replace(/_/g, '/');
  try {
    return Buffer.from(normalised, 'base64');
  } catch {
    return null;
  }
}

export function b64uEncode(buf) {
  return buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** `SHA-256(domain || secret)`, base64url. This is what a store keeps. */
export function lookupOf(domain, secretBytes) {
  return b64uEncode(
    createHash('sha256').update(Buffer.from(domain, 'utf8')).update(secretBytes).digest(),
  );
}

/** 32 bytes of bearer secret. */
export function newSecret() {
  return randomBytes(32);
}

function u64be(n) {
  const b = Buffer.alloc(8);
  b.writeBigUInt64BE(BigInt(n));
  return b;
}

/**
 * The exact bytes a ticket registration signs.
 *
 * Fixed and binary on purpose: signing a JSON rendering would make the
 * signature depend on key order and whitespace, so a client and a server with
 * different serializers would disagree about what was signed.
 */
export function registrationTranscript({
  controlPubkey,
  deviceToken,
  environment,
  topic,
  timestamp,
  nonce,
}) {
  const env = Buffer.from(environment, 'utf8');
  const top = Buffer.from(topic, 'utf8');
  return Buffer.concat([
    Buffer.from(REGISTER_DOMAIN, 'utf8'),
    controlPubkey,
    u64be(deviceToken.length),
    deviceToken,
    env,
    u64be(top.length),
    top,
    u64be(timestamp),
    nonce,
  ]);
}

/**
 * Verify an Ed25519 signature over [message] by a raw 32-byte public key.
 *
 * Node imports keys as SPKI/DER, so the raw key is wrapped in the fixed
 * 12-byte Ed25519 SPKI header rather than asking the client to send DER.
 */
export function verifyEd25519(message, rawPubkey, signature) {
  if (!Buffer.isBuffer(rawPubkey) || rawPubkey.length !== 32) return false;
  if (!Buffer.isBuffer(signature) || signature.length !== 64) return false;
  const spki = Buffer.concat([
    Buffer.from('302a300506032b6570032100', 'hex'),
    rawPubkey,
  ]);
  try {
    const key = createPublicKey({ key: spki, format: 'der', type: 'spki' });
    return verify(null, message, key, signature);
  } catch {
    return false;
  }
}

/**
 * Constant-time-ish equality for short opaque strings. Not a defence against a
 * serious timing attack — the values here are hashes of high-entropy secrets,
 * so an attacker has nothing to steer — but it costs nothing.
 */
export function safeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/**
 * A daily-rotated keyed hash of a client address, for abuse counting.
 *
 * The raw address is never stored: the salt is process-local and rotates, so
 * yesterday's counters cannot be re-linked to an address even from a memory
 * dump taken today.
 */
export function ipBucket(address, salt) {
  return createHash('sha256').update(salt).update(String(address ?? '')).digest('base64');
}
