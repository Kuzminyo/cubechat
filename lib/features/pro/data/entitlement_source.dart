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

  /// Begin a purchase. The result arrives on [changes], not as a return value:
  /// a store purchase can finish minutes later, or on another launch.
  Future<void> buy(ProProduct product);

  Future<void> dispose();
}

/// Overridden in tests, and in `main.dart` with the store-backed source.
final entitlementSourceProvider = Provider<EntitlementSource>(
  (ref) => throw UnimplementedError(
    'entitlementSourceProvider must be overridden before proProvider is read',
  ),
);
