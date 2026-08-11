import 'dart:math';

import 'package:latlong2/latlong.dart';

/// Group points that would land on top of each other on screen.
///
/// Pins are drawn at a fixed size, so how close two people *look* has nothing
/// to do with how close they are — it depends entirely on the zoom. Three
/// friends in one building are one unreadable smear of overlapping discs at
/// every zoom where the building is visible, and the pin on top is the only one
/// that can be tapped at all.
///
/// Greedy single pass, which is what this needs: the input is capped at the
/// eighty most recent pins, and the alternative — proper hierarchical
/// clustering — buys a nicer answer to a question nobody is asking at this
/// size, on every frame of a pinch.
///
/// Each group keeps the input's order, so whatever it was sorted by (most
/// recently seen, here) still decides which face shows first.
List<List<T>> clusterByDistance<T>(
  List<T> items, {
  required LatLng Function(T) pointOf,
  required double thresholdMetres,
}) {
  if (items.length < 2 || thresholdMetres <= 0) {
    return [for (final item in items) [item]];
  }

  const distance = Distance();
  final taken = List<bool>.filled(items.length, false);
  final groups = <List<T>>[];

  for (var i = 0; i < items.length; i++) {
    if (taken[i]) continue;
    taken[i] = true;
    final group = <T>[items[i]];
    final anchor = pointOf(items[i]);
    for (var j = i + 1; j < items.length; j++) {
      if (taken[j]) continue;
      // Measured against the group's anchor rather than against its running
      // centre: a centre that moves as members join can walk a chain of pins
      // across the map, swallowing people who were never near the first one.
      if (distance.as(LengthUnit.Meter, anchor, pointOf(items[j])) <=
          thresholdMetres) {
        taken[j] = true;
        group.add(items[j]);
      }
    }
    groups.add(group);
  }

  return groups;
}

/// How many metres one screen pixel covers at [zoom], at this [latitude].
///
/// The web-mercator ground resolution. It is what turns "these pins overlap"
/// — a question about pixels — into the metres [clusterByDistance] compares,
/// and it is why the same two people cluster when the city is on screen and
/// separate when the street is.
double metresPerPixel(double latitude, double zoom) {
  const equatorMetresPerPixelAtZoomZero = 156543.03392;
  final radians = latitude * (pi / 180);
  return equatorMetresPerPixelAtZoomZero * cos(radians) / pow(2, zoom);
}
