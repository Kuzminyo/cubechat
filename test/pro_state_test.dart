import 'package:cubechat/features/pro/models/pro_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProState', () {
    test('unknown is not active and not loaded', () {
      // The difference that matters on a cold start: we do not yet know, which
      // is not the same as "no". A screen that treats unknown as locked shows
      // a padlock for a moment to somebody who paid.
      expect(ProState.unknown.loaded, isFalse);
      expect(ProState.unknown.isActive, isFalse);
    });

    test('free is loaded and not active', () {
      expect(ProState.free.loaded, isTrue);
      expect(ProState.free.isActive, isFalse);
    });

    test('either paid source is active', () {
      const sub = ProState(source: ProSource.subscription, loaded: true);
      const life = ProState(source: ProSource.lifetime, loaded: true);
      expect(sub.isActive, isTrue);
      expect(life.isActive, isTrue);
    });

    test('compares by value, so an equal rebuild is a no-op', () {
      const a = ProState(source: ProSource.lifetime, loaded: true);
      const b = ProState(source: ProSource.lifetime, loaded: true);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(ProState.free)));
    });

    test('loaded is part of identity', () {
      // Otherwise "not known yet" and "known to be free" collide, and the
      // padlock flash comes back through the equality check.
      const notYet = ProState(source: ProSource.none, loaded: false);
      expect(notYet, isNot(equals(ProState.free)));
    });

    test('store ids round-trip', () {
      for (final p in ProProduct.values) {
        expect(proProductFromStoreId(p.storeId), equals(p));
      }
      expect(proProductFromStoreId('pro.nonsense'), isNull);
    });

    test('store ids are the ones registered in both stores', () {
      expect(ProProduct.monthly.storeId, 'pro.monthly');
      expect(ProProduct.yearly.storeId, 'pro.yearly');
      expect(ProProduct.lifetime.storeId, 'pro.lifetime');
    });

    test('list prices match what the stores are to be configured with', () {
      // These are shown only until the products exist in the stores, and they
      // have to be kept in step with what is registered there — a screen
      // quoting a price nobody will be charged is worse than a dash.
      expect(ProProduct.monthly.listPrice, r'$2');
      expect(ProProduct.yearly.listPrice, r'$20');
      expect(ProProduct.lifetime.listPrice, r'$100');
    });
  });
}
