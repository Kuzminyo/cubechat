import 'package:flutter/foundation.dart';

/// Where the right to Pro came from.
enum ProSource { none, subscription, lifetime }

/// What can be bought. The ids are what both stores are configured with.
enum ProProduct {
  monthly('pro.monthly', r'$2'),
  yearly('pro.yearly', r'$20'),
  lifetime('pro.lifetime', r'$100');

  const ProProduct(this.storeId, this.listPrice);

  final String storeId;

  /// What we intend to charge, shown only while the store has nothing to say.
  ///
  /// The store's own price always wins, and it is the one that is true: it
  /// arrives in the buyer's currency, with their tax and any regional
  /// adjustment already applied, so somebody in Kyiv sees hryvnia rather than
  /// this. These exist so a build made before the products are registered
  /// reads as a price list instead of three dashes — and they must be kept in
  /// step with what is actually registered in Play Console and App Store
  /// Connect.
  final String listPrice;

  ProSource get source =>
      this == ProProduct.lifetime ? ProSource.lifetime : ProSource.subscription;
}

/// The store's id back to the product, or null for anything we do not sell.
ProProduct? proProductFromStoreId(String id) {
  for (final p in ProProduct.values) {
    if (p.storeId == id) return p;
  }
  return null;
}

/// Whether this device may use Pro.
///
/// **No expiry date, deliberately.** `in_app_purchase` reports the status of a
/// purchase, not the day it runs out; an honest end date needs the receipt
/// checked against Apple and Google, which is stage two and needs a server.
/// The store is the source of truth here: past purchases are queried at every
/// launch, and a lapsed subscription simply stops coming back. A field we
/// cannot fill truthfully would be a lie in the type.
@immutable
class ProState {
  const ProState({required this.source, required this.loaded});

  final ProSource source;

  /// False until the store (or the cache) has answered once.
  ///
  /// Kept separate from [isActive] because "not known yet" and "known to be
  /// free" have to look different: a screen that treats the first as the
  /// second shows a padlock for a frame to somebody who paid.
  final bool loaded;

  /// Nothing is known yet — what the controller starts on.
  static const unknown = ProState(source: ProSource.none, loaded: false);

  /// The store has answered, and there is no purchase.
  static const free = ProState(source: ProSource.none, loaded: true);

  bool get isActive => source != ProSource.none;

  ProState copyWith({ProSource? source, bool? loaded}) => ProState(
        source: source ?? this.source,
        loaded: loaded ?? this.loaded,
      );

  @override
  bool operator ==(Object other) =>
      other is ProState && other.source == source && other.loaded == loaded;

  @override
  int get hashCode => Object.hash(source, loaded);
}
