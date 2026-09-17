import 'package:cubechat/features/pro/data/store_entitlement_source.dart';
import 'package:cubechat/features/pro/models/pro_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('proStateFromOwned', () {
    test('nothing owned is free, and it is loaded', () {
      // Loaded matters: the store answered, and the answer was no.
      expect(proStateFromOwned(const <String>[]), equals(ProState.free));
    });

    test('a subscription is a subscription', () {
      expect(
        proStateFromOwned(const ['pro.monthly']).source,
        ProSource.subscription,
      );
      expect(
        proStateFromOwned(const ['pro.yearly']).source,
        ProSource.subscription,
      );
    });

    test('lifetime wins over a subscription', () {
      // Somebody who subscribed and later bought lifetime keeps lifetime when
      // the subscription lapses; reporting the subscription would take Pro
      // away from a person who paid for it once and for all.
      expect(
        proStateFromOwned(const ['pro.monthly', 'pro.lifetime']).source,
        ProSource.lifetime,
      );
      expect(
        proStateFromOwned(const ['pro.lifetime', 'pro.yearly']).source,
        ProSource.lifetime,
      );
    });

    test('an id we do not sell is ignored', () {
      expect(proStateFromOwned(const ['pro.something_else']).isActive, isFalse);
    });

    test('always reports itself as loaded', () {
      expect(proStateFromOwned(const ['pro.lifetime']).loaded, isTrue);
      expect(proStateFromOwned(const <String>[]).loaded, isTrue);
    });
  });
}
