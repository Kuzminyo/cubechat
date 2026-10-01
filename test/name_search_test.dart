import 'package:cubechat/features/cube_id/domain/name_search.dart';
import 'package:flutter_test/flutter_test.dart';

/// "@dima" in a search found nobody, even a contact found by that very name.
void main() {
  group('matchesPeerSearch', () {
    test('an @name finds the contact it belongs to', () {
      expect(
        matchesPeerSearch(query: '@dima', peerName: 'Дмитро', cubeName: 'dima'),
        isTrue,
      );
      expect(
        matchesPeerSearch(query: 'dim', peerName: 'Дмитро', cubeName: 'dima'),
        isTrue,
      );
    });

    test('the display name still matches, with or without an @', () {
      expect(matchesPeerSearch(query: 'Дми', peerName: 'Дмитро'), isTrue);
      expect(matchesPeerSearch(query: '@дми', peerName: 'Дмитро'), isTrue);
    });

    test('a bare @ hides nobody', () {
      expect(matchesPeerSearch(query: '@', peerName: 'Ann'), isTrue);
    });

    test('no match is no match', () {
      expect(
        matchesPeerSearch(query: '@olga', peerName: 'Ann', cubeName: 'ann_k'),
        isFalse,
      );
    });
  });

  group('cubeNameToLookUp', () {
    test('an unknown @name is offered for lookup, normalised', () {
      expect(cubeNameToLookUp(' @Olga_7 ', knownNames: const []), 'olga_7');
    });

    test('only when written with the @', () {
      expect(cubeNameToLookUp('olga_7', knownNames: const []), isNull);
    });

    test('not for an invalid name', () {
      expect(cubeNameToLookUp('@ab', knownNames: const []), isNull);
      expect(cubeNameToLookUp('@олег', knownNames: const []), isNull);
    });

    test('not for a contact already known by it, nor for oneself', () {
      expect(cubeNameToLookUp('@dima', knownNames: const ['dima']), isNull);
      expect(
        cubeNameToLookUp('@me_here', knownNames: const [], ownName: 'me_here'),
        isNull,
      );
    });
  });
}
