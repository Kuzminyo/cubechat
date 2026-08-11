import 'package:cubechat/features/map/data/map_clusters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  const centre = LatLng(50.4501, 30.5234);

  LatLng north(double metres) => const Distance().offset(centre, metres, 0);

  group('clusterByDistance', () {
    test('folds pins that would be drawn on top of each other', () {
      final groups = clusterByDistance(
        [centre, north(20), north(400)],
        pointOf: (p) => p,
        thresholdMetres: 100,
      );

      expect(groups.length, 2);
      expect(groups.first.length, 2);
      expect(groups.last.single, north(400));
    });

    test('measures from the anchor, not from a moving centre', () {
      // Three pins 80 m apart in a line, with a 100 m threshold. Against a
      // running centre this walks: the first swallows the second, the centre
      // slides, and the third joins a group it was never near. The first and
      // last are 160 m apart and must not end up together.
      final groups = clusterByDistance(
        [centre, north(80), north(160)],
        pointOf: (p) => p,
        thresholdMetres: 100,
      );

      expect(groups.first.length, 2);
      expect(groups.last.single, north(160));
    });

    test('keeps the order it was given', () {
      final groups = clusterByDistance(
        ['a', 'b'],
        pointOf: (id) => id == 'a' ? centre : north(10),
        thresholdMetres: 100,
      );

      expect(groups.single, ['a', 'b']);
    });

    test('one pin is one group, and nothing clusters at zero', () {
      expect(
        clusterByDistance([centre], pointOf: (p) => p, thresholdMetres: 100)
            .single
            .single,
        centre,
      );
      expect(
        clusterByDistance(
          [centre, north(1)],
          pointOf: (p) => p,
          thresholdMetres: 0,
        ).length,
        2,
      );
    });
  });

  group('metresPerPixel', () {
    test('halves with every zoom level', () {
      final near = metresPerPixel(0, 10);
      final far = metresPerPixel(0, 9);

      expect(far / near, closeTo(2, 0.0001));
    });

    test('shrinks away from the equator', () {
      // Web mercator: the same pixel covers less ground the further north you
      // are, which is why the threshold cannot be a fixed number of metres.
      expect(metresPerPixel(60, 12), lessThan(metresPerPixel(0, 12)));
    });
  });
}
