/// What can be bought, and how many cubes it is worth.
///
/// **This table is the only authority on the amount.** The phone sends a
/// receipt and a product id; how many cubes that product is worth is decided
/// here and never read from the request. A client that could name its own
/// amount is a client that credits itself.
///
/// The prices are an intention, not a fact. Apple picks from a grid of tiers
/// and some countries have no exact match, so what the buyer is actually
/// charged is whatever the store shows them — the app reads it from there and
/// never prints its own. They live here so the ladder can be checked for the
/// one property it must have, below.
export const PRODUCTS = Object.freeze({
  'cubes.100': { cubes: 100, usd: 1.99 },
  'cubes.200': { cubes: 200, usd: 3.79 },
  'cubes.300': { cubes: 300, usd: 5.49 },
  'cubes.500': { cubes: 500, usd: 8.49 },
  'cubes.1000': { cubes: 1000, usd: 15.99 },
  'cubes.2000': { cubes: 2000, usd: 29.99 },
  'cubes.5000': { cubes: 5000, usd: 69.99 },
});

/// The smallest thing anyone can buy. Below this the store's cut and the
/// support cost of a purchase are most of the purchase.
export const MIN_CUBES = 100;

/// How many cubes [productId] is worth, or null for anything we do not sell.
///
/// Null rather than a throw: an unknown id arriving here means an old build,
/// a typo in the console, or somebody trying it on, and none of those deserve
/// a stack trace.
export function cubesFor(productId) {
  return PRODUCTS[productId]?.cubes ?? null;
}

/// The ladder, cheapest first.
export function ladder() {
  return Object.entries(PRODUCTS)
    .map(([id, p]) => ({ id, ...p, perCube: p.usd / p.cubes }))
    .sort((a, b) => a.cubes - b.cubes);
}
