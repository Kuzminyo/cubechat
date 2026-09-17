import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/pro_state.dart';

/// Where the answer "may this device use Pro" comes from.
///
/// There are two of these by design. This stage has one — the store receipt on
/// the device — and stage two adds blind-signed tokens for the parts the relay
/// has to enforce. Keeping the seam here is what stops the second from being a
/// rewrite of the first.
abstract interface class EntitlementSource {
  /// Everything this source learns, starting with whatever it knows already.
  Stream<ProState> get changes;

  /// Connect, and ask for what is already owned.
  Future<void> start();

  /// Ask the store again for past purchases.
  Future<void> restore();

  /// Begin a purchase. The *outcome* arrives on [changes], not here: a store
  /// purchase can finish minutes later, or on another launch.
  ///
  /// What comes back is only whether the store accepted the attempt. False
  /// means it could not be started at all — most often because the product is
  /// not registered in the store yet — and the screen says so. It is
  /// deliberately not an error on [changes]: a product missing from the store
  /// is not evidence that somebody's subscription broke, and pushing it there
  /// filled the diagnostics log with red lines that were not faults.
  Future<bool> buy(ProProduct product);

  /// What each product costs, formatted by the store in the buyer's currency.
  ///
  /// Empty for anything the store does not know, which is every product until
  /// they are registered. The screen shows a dash rather than inventing a
  /// number.
  Future<Map<ProProduct, String>> prices();

  Future<void> dispose();
}

/// Overridden in tests, and in `main.dart` with the store-backed source.
final entitlementSourceProvider = Provider<EntitlementSource>(
  (ref) => throw UnimplementedError(
    'entitlementSourceProvider must be overridden before proProvider is read',
  ),
);
