import { cubesFor } from './products.js';

/// Believing the store, and never the phone.
///
/// The phone sends a receipt and says what it bought. Both halves of that are
/// under the buyer's control — a modified build can say anything — so nothing
/// here is taken from the request except the token to go and ask about. The
/// amount comes from our own catalogue, the product comes from the store's
/// answer, and the reference that makes the credit idempotent comes from the
/// store's transaction id.
///
/// Every failure is null. In particular a network failure is null: "we could
/// not reach Apple, so let them through" is the most expensive default in this
/// file, and it is the one that looks like kindness.
///
/// The two store calls are injected so this runs in a unit test with no
/// network, no credentials and no store. `deps` is `{ appleTransaction,
/// googlePurchase }`; the live pair lives in [liveDeps].

export async function verifyPurchase(
  { platform, token, productId },
  deps,
) {
  if (typeof token !== 'string' || token.length === 0) return null;

  try {
    if (platform === 'apple') {
      const tx = await deps.appleTransaction(token);
      if (!tx || tx.revoked) return null;
      return credit('apple', tx.transactionId, tx.productId, productId);
    }
    if (platform === 'google') {
      const purchase = await deps.googlePurchase({ productId, token });
      // 0 is purchased. 1 is cancelled and 2 is pending, and neither is money
      // yet — crediting a pending purchase is crediting one that may never
      // complete.
      if (!purchase || purchase.purchaseState !== 0) return null;
      return credit('google', purchase.orderId, productId, productId);
    }
  } catch {
    // Unreachable store, malformed answer, expired credentials. All the same
    // answer, and the answer is no.
    return null;
  }
  return null;
}

/// The last gate: the store's product must be one we sell, and must be the one
/// the phone claimed.
///
/// Checking both is not belt and braces. Trusting only the store's product
/// would credit a purchase the phone asked about for something else; trusting
/// only the phone's would let a receipt for the cheapest pack be presented as
/// the dearest.
function credit(platform, transactionId, storeProduct, claimedProduct) {
  if (typeof transactionId !== 'string' || transactionId.length === 0) {
    return null;
  }
  if (storeProduct !== claimedProduct) return null;
  const cubes = cubesFor(storeProduct);
  if (cubes === null) return null;
  return { ref: `${platform}:${transactionId}`, cubes };
}

/// The real calls, kept apart from the logic above so the logic can be tested.
///
/// Both need credentials, and both read them from the environment — never from
/// the repository. `APPLE_ISSUER_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY` for
/// the App Store Server API; `GOOGLE_SERVICE_ACCOUNT_JSON` and
/// `GOOGLE_PACKAGE_NAME` for `purchases.products.get`.
///
/// Not implemented here yet: this lands with the deploy, where the credentials
/// exist. Until then the service is wired with a deps object that refuses
/// everything, which is the correct behaviour for a wallet with no way to
/// check a receipt.
export function liveDeps() {
  return {
    async appleTransaction() {
      throw new Error('apple credentials are not configured');
    },
    async googlePurchase() {
      throw new Error('google credentials are not configured');
    },
  };
}
