import 'dart:math';
import 'dart:typed_data';

import 'package:cubechat/core/transport/relay_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List id(int seed) =>
      Uint8List.fromList(List<int>.generate(16, (i) => (seed * 31 + i) & 0xff));

  List<String> links(int n) => [for (var i = 0; i < n; i++) 'peer$i'];

  group('relayLinkCount', () {
    test('one or two links get everything — a chain must not break', () {
      expect(relayLinkCount(0), 0);
      expect(relayLinkCount(1), 1);
      expect(relayLinkCount(2), 2);
    });

    test('more links get about log2 of them, never fewer than two', () {
      expect(relayLinkCount(3), 2);
      expect(relayLinkCount(4), 2);
      expect(relayLinkCount(5), 3);
      expect(relayLinkCount(8), 3);
      expect(relayLinkCount(9), 4);
      expect(relayLinkCount(16), 4);
    });
  });

  group('relayLinkSubset', () {
    test('is deterministic for one message and picks the right number', () {
      final a = relayLinkSubset(links(8), id(1));
      final b = relayLinkSubset(links(8).reversed.toList(), id(1));
      expect(a.length, 3);
      expect(a, b, reason: 'the order links are listed in must not matter');
    });

    test('different messages spread over different links', () {
      final seen = <String>{};
      for (var m = 0; m < 40; m++) {
        seen.addAll(relayLinkSubset(links(8), id(m)));
      }
      expect(seen.length, 8, reason: 'every link carries some of the traffic');
    });

    test('small neighbourhoods are not thinned', () {
      expect(relayLinkSubset(links(2), id(3)).toSet(), links(2).toSet());
    });
  });

  group('relayJitter', () {
    test('stays inside 10–220 ms when sparse and 10–400 ms when dense', () {
      final rng = Random(7);
      for (var i = 0; i < 500; i++) {
        final sparse = relayJitter(linkCount: 3, random: rng).inMilliseconds;
        final dense = relayJitter(linkCount: 7, random: rng).inMilliseconds;
        expect(sparse, inInclusiveRange(10, 220));
        expect(dense, inInclusiveRange(10, 400));
      }
    });
  });
}
