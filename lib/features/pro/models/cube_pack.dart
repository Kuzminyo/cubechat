/// One rung of the cubes ladder.
///
/// The same table the wallet server holds, and deliberately duplicated rather
/// than fetched: this one decides what to *show*, and the server's decides
/// what to *credit*. A phone that could be told how many cubes a product is
/// worth is a phone that can be told it is worth a million — so the only
/// authority on the amount is on the server, and this copy exists so the
/// screen has something to draw before anybody is asked for money.
///
/// If the two ever disagree, the server wins and the buyer gets what the
/// server says. The list price here is likewise a fallback: once the products
/// exist in the stores, the price shown is whatever the store quotes, in the
/// buyer's own currency.
enum CubePack {
  p100('cubes.100', 100, r'$1.99'),
  p200('cubes.200', 200, r'$3.79'),
  p300('cubes.300', 300, r'$5.49'),
  p500('cubes.500', 500, r'$8.49'),
  p1000('cubes.1000', 1000, r'$15.99'),
  p2000('cubes.2000', 2000, r'$29.99'),
  p5000('cubes.5000', 5000, r'$69.99');

  const CubePack(this.storeId, this.cubes, this.listPrice);

  final String storeId;
  final int cubes;
  final String listPrice;

  /// Smallest first, which is the order the screen draws them in.
  static List<CubePack> get ladder => values.toList()
    ..sort((a, b) => a.cubes.compareTo(b.cubes));

  static CubePack? fromStoreId(String id) {
    for (final p in values) {
      if (p.storeId == id) return p;
    }
    return null;
  }
}
