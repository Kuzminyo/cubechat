#!/usr/bin/env node
// Run once per deployment: `node push/tool/gen_ban_key.mjs`.
//
// Prints two lines and nothing else — no file is written, because a private
// key printed to disk by a tool is a private key somebody forgets is there.
// The first line is the server's secret and goes into `BAN_SIGNING_KEY` in
// the systemd unit's environment file (see `push/deploy/README.md`). The
// second is public and goes into the app as `banListPublicKeyHex`
// (`lib/features/moderation/data/ban_list_controller.dart`, Task A6) — it is
// what every phone verifies the signed list against, so it ships in the app
// binary, not in an env file.
//
// Raw, not DER, for the public key: the app's Ed25519 verify takes the 32
// raw bytes, the same shape every other key in this codebase is carried in
// (compare the secp256k1 pubkeys throughout `src/index.js`). The last 32
// bytes of the SPKI DER *are* those raw bytes — SPKI is a fixed 12-byte
// algorithm-identifier prefix followed by the raw public key for Ed25519,
// per RFC 8410 — so slicing is exact, not a guess.
import { generateKeyPairSync } from 'node:crypto';

const { publicKey, privateKey } = generateKeyPairSync('ed25519');

const pkcs8 = privateKey.export({ type: 'pkcs8', format: 'der' }).toString('base64');
const spki = publicKey.export({ type: 'spki', format: 'der' });
const rawPublicHex = spki.subarray(spki.length - 32).toString('hex');

process.stdout.write(`BAN_SIGNING_KEY=${pkcs8}\n`);
process.stdout.write(`APP_PUBLIC_KEY_HEX=${rawPublicHex}\n`);
