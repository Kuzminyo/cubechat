import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../models/pro_state.dart';
import 'entitlement_source.dart';

/// What the set of owned product ids means.
///
/// Separated from the plugin on purpose: this is the whole of the logic, and
/// it runs in a plain unit test on a machine with no store and no phone.
ProState proStateFromOwned(Iterable<String> ownedStoreIds) {
  var source = ProSource.none;
  for (final id in ownedStoreIds) {
    final product = proProductFromStoreId(id);
    if (product == null) continue;
    // Lifetime outranks a subscription: somebody who has both keeps Pro when
    // the subscription lapses.
    if (product.source == ProSource.lifetime) {
      return const ProState(source: ProSource.lifetime, loaded: true);
    }
    source = ProSource.subscription;
  }
  return ProState(source: source, loaded: true);
}

/// The store receipt on this device, and nothing else.
///
/// No server is told about the purchase. That is the whole of stage one: what
/// it can gate is what costs nothing to run, and a modified build walking past
/// it costs us nothing either. The parts the relay has to enforce wait for the
/// blind-signed tokens of stage two.
class StoreEntitlementSource implements EntitlementSource {
  StoreEntitlementSource({InAppPurchase? iap}) : _injected = iap;

  final InAppPurchase? _injected;

  /// Resolved lazily and never before [_storeExists] has been checked.
  ///
  /// `InAppPurchase.instance` reaches for a platform implementation that the
  /// Windows and web builds do not have, and this app builds for both to work
  /// on the interface. Touching it in the constructor would take the whole app
  /// down at launch on a developer's desktop.
  InAppPurchase get _iap => _injected ?? InAppPurchase.instance;

  final _out = StreamController<ProState>.broadcast();
  final _owned = <String>{};
  StreamSubscription<List<PurchaseDetails>>? _sub;

  static bool get _storeExists =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  Stream<ProState> get changes => _out.stream;

  @override
  Future<void> start() async {
    // A desktop or web build has no store. Not an error, and not a reason to
    // claim Pro: the answer is a plain no, and it is a final one.
    if (!_storeExists) {
      _out.add(ProState.free);
      return;
    }
    _sub = _iap.purchaseStream.listen(
      _apply,
      onError: (Object e) => _out.addError(e),
    );
    if (!await _iap.isAvailable()) {
      // A phone without Play services, or a store that is out of reach.
      _out.add(ProState.free);
      return;
    }
    await restore();
  }

  @override
  Future<void> restore() async {
    if (!_storeExists) return;
    await _iap.restorePurchases();
  }

  @override
  Future<void> buy(ProProduct product) async {
    if (!_storeExists) return;
    final response = await _iap.queryProductDetails({product.storeId});
    ProductDetails? details;
    for (final d in response.productDetails) {
      if (d.id == product.storeId) details = d;
    }
    if (details == null) {
      _out.addError(StateError('product ${product.storeId} not in the store'));
      return;
    }
    final param = PurchaseParam(productDetails: details);
    // Both the subscription and the lifetime unlock are non-consumable as far
    // as the plugin is concerned: neither is bought twice over.
    await _iap.buyNonConsumable(purchaseParam: param);
  }

  void _apply(List<PurchaseDetails> purchases) {
    for (final p in purchases) {
      final owned = p.status == PurchaseStatus.purchased ||
          p.status == PurchaseStatus.restored;
      if (owned) {
        _owned.add(p.productID);
      } else if (p.status == PurchaseStatus.error) {
        debugPrint('Purchase failed: ${p.error}');
      }
      // Pending and canceled change nothing: the first has not happened yet
      // and the second did not happen.
      if (p.pendingCompletePurchase) {
        unawaited(_iap.completePurchase(p));
      }
    }
    _out.add(proStateFromOwned(_owned));
  }

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    await _out.close();
  }
}
