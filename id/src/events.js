import { schnorr } from '@noble/curves/secp256k1';
import { sha256 } from '@noble/hashes/sha256';
import { bytesToHex, utf8ToBytes } from '@noble/hashes/utils';

/// Kind of every Cube ID operation — its own, not push's 24242, so a push
/// registration can never be replayed here or the other way round.
export const KIND = 24243;
/// NIP-13 difficulty demanded on claim and rename — a deterrent against
/// scripted mass claims, beside the rate limit. 14, not 16: 16 bits measured
/// up to 3.8 s on a PC (mean 0.77 s, 2026-09-29) and a phone is slower. Must
/// equal `cubeIdPowBits` in lib/features/cube_id/data/cube_id_events.dart.
export const POW_BITS = 14;
export const MAX_PAST = 300;
export const MAX_FUTURE = 60;

// Same checks as verifyEvent in push/src/index.js: the id is the hash of the
// canonical form and the signature verifies against the pubkey in it.
export function verifyEvent(event) {
  if (
    typeof event?.pubkey !== 'string' || typeof event?.id !== 'string' ||
    typeof event?.sig !== 'string' || typeof event?.content !== 'string' ||
    typeof event?.created_at !== 'number' || !Array.isArray(event?.tags) ||
    event?.kind !== KIND
  ) return false;
  if (!/^[0-9a-f]{64}$/.test(event.pubkey) || !/^[0-9a-f]{64}$/.test(event.id) ||
      !/^[0-9a-f]{128}$/.test(event.sig)) return false;
  const canonical = JSON.stringify([0, event.pubkey, event.created_at, event.kind, event.tags, event.content]);
  if (bytesToHex(sha256(utf8ToBytes(canonical))) !== event.id) return false;
  try {
    return schnorr.verify(event.sig, event.id, event.pubkey);
  } catch {
    return false;
  }
}

// NIP-13: the number of leading zero bits of the event id.
export function difficulty(idHex) {
  let bits = 0;
  for (const ch of idHex) {
    const v = parseInt(ch, 16);
    if (v === 0) { bits += 4; continue; }
    return bits + Math.clz32(v) - 28;
  }
  return bits;
}
