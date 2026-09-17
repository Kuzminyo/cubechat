import { createServer } from 'node:http';

import { authorise, AuthError } from './auth.js';
import { liveDeps, verifyPurchase } from './receipts.js';
import { openStore } from './store.js';

/// The wallet service.
///
/// Three endpoints and one rule: the signature on the request says who is
/// spending, and no npub is ever read from a body. Everything else here is
/// plumbing around [authorise] and [openStore].
///
/// Deliberately separate from the push doorbell — its own process, its own
/// database, its own unit. A wallet that falls over must not take the thing
/// that says "you have mail" with it.

const DB = process.env.CUBECHAT_WALLET_DB ?? 'cubes.db';
const MAX_BODY = 8 * 1024;

export const store = openStore(DB);

/// How the service reaches Apple and Google.
///
/// Swappable so a test can answer for both without a network or a credential.
/// The live pair refuses everything until the deploy configures it, which is
/// the right behaviour for a wallet that has no way to check a receipt: a
/// purchase it cannot verify is a purchase it does not credit.
let purchaseDeps = liveDeps();

export function setPurchaseDeps(deps) {
  purchaseDeps = deps;
}

function send(res, status, body) {
  const text = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json',
    'content-length': Buffer.byteLength(text),
  });
  res.end(text);
}

/// Read the body, refusing anything large enough to be an attack rather than a
/// request. Every request here is a few hundred bytes of signed event.
function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY) {
        reject(new AuthError('malformed', 'body too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch {
        reject(new AuthError('malformed', 'body is not JSON'));
      }
    });
    req.on('error', reject);
  });
}

/// A whole positive number written in a tag, or null.
///
/// Tags are strings on the wire, and `Number('')` is 0 — which would be an
/// amount of nothing accepted as a valid one.
function amountFrom(text) {
  if (!/^[0-9]+$/.test(text ?? '')) return null;
  const n = Number(text);
  return Number.isSafeInteger(n) && n > 0 ? n : null;
}

const handlers = {
  balance(claim) {
    return { cubes: store.balanceOf(claim.npub) };
  },

  /// Turn a store receipt into cubes.
  ///
  /// The tags say which store and which product, and carry the token to go and
  /// ask about. How many cubes that is worth, and the reference that makes the
  /// credit happen once, both come back from the store — see [verifyPurchase].
  async credit(claim) {
    const platform = claim.tag('platform');
    const token = claim.tag('token');
    const productId = claim.tag('product');
    if (!platform || !token || !productId) {
      throw new AuthError('purchase', 'platform, token and product required');
    }
    const purchase = await verifyPurchase(
      { platform, token, productId },
      purchaseDeps,
    );
    // One answer for every way a receipt can fail to be one. Which way it
    // failed is between us and the store.
    if (!purchase) throw new AuthError('receipt', 'not a purchase we can see');

    store.credit({
      npub: claim.npub,
      amount: purchase.cubes,
      ref: purchase.ref,
      source: platform,
    });
    return { cubes: store.balanceOf(claim.npub) };
  },

  transfer(claim) {
    const to = claim.tag('to');
    const amount = amountFrom(claim.tag('amount'));
    const ref = claim.tag('id');
    if (!/^[0-9a-f]{64}$/.test(to ?? '')) {
      throw new AuthError('recipient', 'to must be 64 lower-case hex');
    }
    if (amount === null) throw new AuthError('amount', 'amount must be whole');
    if (!ref) throw new AuthError('ref', 'id is required so a repeat is safe');
    // `from` is the signer and nothing else. A body or a tag naming a payer is
    // ignored, which is what stops this endpoint from emptying any balance
    // whose owner is known.
    store.transfer({ from: claim.npub, to, amount, ref });
    return { cubes: store.balanceOf(claim.npub) };
  },
};

export const server = createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    return send(res, 200, { ok: true });
  }
  if (req.method !== 'POST') return send(res, 405, { error: 'method' });

  let claim;
  try {
    const body = await readBody(req);
    claim = authorise(body?.event ?? null);
  } catch (e) {
    // Everything that fails before the signature checks out is one answer:
    // 401 and a code. Telling a caller *which* part of their forgery failed
    // is help they have not earned.
    return send(res, 401, { error: e instanceof AuthError ? e.code : 'auth' });
  }

  const handler = handlers[claim.op];
  if (!handler) return send(res, 404, { error: 'op' });

  try {
    // Awaited: crediting has to ask a store, and the rest do not — but a
    // non-promise awaits to itself, so both shapes go through one path.
    return send(res, 200, await handler(claim));
  } catch (e) {
    // A refusal the caller can act on: not enough cubes, a bad recipient. The
    // ledger and auth errors both carry a code; anything else is ours and says
    // nothing about itself.
    if (e?.code) return send(res, 400, { error: e.code });
    return send(res, 500, { error: 'internal' });
  }
});

// Started only when run directly, so a test can import `server` and listen on
// a port of its own — the same shape the doorbell uses.
if (process.argv[1]?.endsWith('index.js')) {
  const port = Number(process.env.PORT ?? 8788);
  server.listen(port, '127.0.0.1');
}
