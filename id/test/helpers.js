import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { schnorr } from '@noble/curves/secp256k1';

export const T0 = 1_790_000_000; // seconds

export function nostrPub(key) {
  return Buffer.from(schnorr.getPublicKey(key)).toString('hex');
}

// A v5 card in the app's layout, signed with a fresh Ed25519 key.
export function cardFor(nostrHex, nickname = 'Dima') {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const edRaw = Buffer.from(publicKey.export({ format: 'jwk' }).x, 'base64url');
  const nick = Buffer.from(nickname, 'utf8');
  const body = Buffer.concat([
    Buffer.from([0x05]),
    Buffer.alloc(32, 1), edRaw, Buffer.alloc(32, 3),
    Buffer.from(nostrHex, 'hex'),
    Buffer.from([nick.length]), nick, Buffer.alloc(32, 0),
  ]);
  return new Uint8Array(Buffer.concat([body, sign(null, body, privateKey)]));
}

function idOf(e) {
  return createHash('sha256')
    .update(JSON.stringify([0, e.pubkey, e.created_at, e.kind, e.tags, e.content]))
    .digest('hex');
}

function zeroBits(hex) {
  let n = 0;
  for (const ch of hex) {
    const v = parseInt(ch, 16);
    if (v === 0) { n += 4; continue; }
    n += Math.clz32(v) - 28;
    break;
  }
  return n;
}

export function signedOp(content, { key = '01'.repeat(32), createdAt = T0, powBits = 16 } = {}) {
  const pubkey = nostrPub(key);
  const e = { pubkey, created_at: createdAt, kind: 24243, tags: [], content: JSON.stringify(content) };
  if (powBits > 0) {
    for (let nonce = 0; ; nonce++) {
      e.tags = [['nonce', String(nonce), String(powBits)]];
      e.id = idOf(e);
      if (zeroBits(e.id) >= powBits) break;
    }
  } else {
    e.id = idOf(e);
  }
  e.sig = Buffer.from(schnorr.sign(e.id, key)).toString('hex');
  return e;
}

export const b64u = (bytes) => Buffer.from(bytes).toString('base64url');
