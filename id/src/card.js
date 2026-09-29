// Reads a PeerAnnouncement exactly as lib/core/transport/announcement.dart
// writes it, and checks its Ed25519 signature. The registry never trusts a
// card it has not verified, and the phone verifies it again on lookup.

import { createPublicKey, verify } from 'node:crypto';

const VERSION = 0x05;
const VERSION_NO_AVATAR = 0x04;
const KEY = 32;
const SIG = 64;
const AVATAR = 32;

function invalid(why) {
  const error = new Error(`card: ${why}`);
  error.code = 'card-invalid';
  return error;
}

const hex = (b) => Buffer.from(b).toString('hex');

export function parseCard(bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.length < 1 + KEY * 4 + 1 + SIG) {
    throw invalid('truncated');
  }
  const version = bytes[0];
  if (version !== VERSION && version !== VERSION_NO_AVATAR) throw invalid('version');
  let c = 1;
  const x25519 = bytes.subarray(c, (c += KEY));
  const ed25519 = bytes.subarray(c, (c += KEY));
  const prekey = bytes.subarray(c, (c += KEY));
  const nostr = bytes.subarray(c, (c += KEY));
  const nlen = bytes[c++];
  const avatarBytes = version === VERSION ? AVATAR : 0;
  // Exact, where the app's decoder only checks for enough bytes: the registry
  // stores these bytes, and must not store trailing junk with them.
  if (bytes.length !== c + nlen + avatarBytes + SIG) throw invalid('length');
  const nickname = Buffer.from(bytes.subarray(c, c + nlen)).toString('utf8');
  c += nlen + avatarBytes;
  const body = bytes.subarray(0, c);
  const sig = bytes.subarray(c, c + SIG);
  let ok = false;
  try {
    const key = createPublicKey({
      key: { kty: 'OKP', crv: 'Ed25519', x: Buffer.from(ed25519).toString('base64url') },
      format: 'jwk',
    });
    ok = verify(null, body, key, sig);
  } catch {
    ok = false;
  }
  if (!ok) throw invalid('signature');
  return {
    version,
    x25519Hex: hex(x25519),
    ed25519Hex: hex(ed25519),
    prekeyHex: hex(prekey),
    nostrHex: hex(nostr),
    nickname,
  };
}
