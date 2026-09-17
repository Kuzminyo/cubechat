import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../models/cube_pack.dart';
import 'wallet_client.dart';

/// What the cubes screen draws.
@immutable
class CubesState {
  const CubesState({
    required this.balance,
    required this.loaded,
    this.buying,
    this.prices = const <String, String>{},
  });

  final int balance;

  /// False until the wallet has answered once. Showing zero to somebody who
  /// has cubes is worse than showing nothing at all.
  final bool loaded;

  /// The store id of a purchase in flight, if there is one.
  final String? buying;

  /// Store prices by product id, empty until the products exist there.
  final Map<String, String> prices;

  static const unknown = CubesState(balance: 0, loaded: false);

  String? priceOf(CubePack pack) => prices[pack.storeId];

  CubesState copyWith({
    int? balance,
    bool? loaded,
    String? buying,
    bool clearBuying = false,
    Map<String, String>? prices,
  }) =>
      CubesState(
        balance: balance ?? this.balance,
        loaded: loaded ?? this.loaded,
        buying: clearBuying ? null : (buying ?? this.buying),
        prices: prices ?? this.prices,
      );
}

/// Buying cubes, and knowing how many there are.
///
/// The purchase is a consumable: bought, credited, consumed, and buyable
/// again. The credit happens on the server against the store's own answer —
/// this class never says how many cubes anything is worth, and there is no
/// parameter here that could.
///
/// **The store purchase is completed only after the server has credited it.**
/// The other order loses money: a completed purchase the server never saw is
/// a receipt the store will not show again, and the buyer has paid for
/// nothing. Leaving it uncompleted means the store re-delivers it on the next
/// launch, which is exactly the retry that is wanted.
class CubesController extends Notifier<CubesState> {
  StreamSubscription<List<PurchaseDetails>>? _sub;

  @override
  CubesState build() {
    unawaited(refresh());
    return CubesState.unknown;
  }

  /// Ask the wallet what the balance is.
  Future<void> refresh() async {
    final reply = await ref.read(walletApiProvider).balance();
    if (reply case WalletOk(:final cubes)) {
      state = state.copyWith(balance: cubes, loaded: true);
    }
    // A refusal or an unreachable server leaves `loaded` false, and the screen
    // keeps showing a dash rather than inventing a zero.
  }

  /// Listen for purchases and begin one.
  ///
  /// Started lazily from the screen rather than at launch: nobody who never
  /// opens this screen should be paying for a purchase stream.
  Future<void> buy(CubePack pack) async {
    if (state.buying != null) return;
    _listen();
    state = state.copyWith(buying: pack.storeId);
    try {
      final iap = InAppPurchase.instance;
      final response = await iap.queryProductDetails({pack.storeId});
      ProductDetails? details;
      for (final d in response.productDetails) {
        if (d.id == pack.storeId) details = d;
      }
      if (details == null) {
        state = state.copyWith(clearBuying: true);
        return;
      }
      await iap.buyConsumable(purchaseParam: PurchaseParam(productDetails: details));
    } catch (e) {
      debugPrint('cubes purchase failed to start: $e');
      state = state.copyWith(clearBuying: true);
    }
  }

  void _listen() {
    _sub ??= InAppPurchase.instance.purchaseStream.listen(
      _apply,
      onError: (Object e) => debugPrint('cubes purchase stream: $e'),
    );
    ref.onDispose(() => unawaited(_sub?.cancel()));
  }

  Future<void> _apply(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      final bought = purchase.status == PurchaseStatus.purchased ||
          purchase.status == PurchaseStatus.restored;
      if (!bought) {
        if (purchase.status == PurchaseStatus.error ||
            purchase.status == PurchaseStatus.canceled) {
          state = state.copyWith(clearBuying: true);
        }
        continue;
      }

      final reply = await ref.read(walletApiProvider).credit(
            platform: defaultTargetPlatform == TargetPlatform.iOS
                ? 'apple'
                : 'google',
            token: purchase.verificationData.serverVerificationData,
            productId: purchase.productID,
          );

      if (reply case WalletOk(:final cubes)) {
        state = state.copyWith(balance: cubes, loaded: true, clearBuying: true);
        // Completed only now. Before the credit, an interrupted app would have
        // left a paid-for purchase the store considers delivered and the
        // server never saw.
        if (purchase.pendingCompletePurchase) {
          await InAppPurchase.instance.completePurchase(purchase);
        }
      } else {
        // Left uncompleted on purpose: the store re-delivers it next launch
        // and the credit is tried again.
        state = state.copyWith(clearBuying: true);
        debugPrint('cubes credit not applied: $reply');
      }
    }
  }
}

final cubesProvider =
    NotifierProvider<CubesController, CubesState>(CubesController.new);
