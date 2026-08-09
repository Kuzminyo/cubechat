import 'package:flutter/widgets.dart';
import 'package:geocoding/geocoding.dart';

/// Resolves one compact label for the point at the centre of the map.
///
/// The operating system owns the reverse-geocoding backend. The map screen
/// calls this only after a gesture has ended, so panning never waits on it and
/// Android/iOS rate limits are not hit by every animation frame.
class MapAddressService {
  const MapAddressService();

  Future<String?> read(
    double latitude,
    double longitude,
    Locale locale,
  ) async {
    try {
      final places = await Geocoding(locale: locale).placemarkFromCoordinates(
        latitude,
        longitude,
      );
      if (places.isEmpty) return null;
      return compactLabel(places.first);
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static String? compactLabel(Placemark place) {
    String? clean(String? value) {
      final text = value?.trim();
      return text == null || text.isEmpty ? null : text;
    }

    final street = clean(place.street) ?? clean(place.thoroughfare);
    final city = clean(place.locality) ??
        clean(place.subAdministrativeArea) ??
        clean(place.administrativeArea);

    if (street != null && city != null) {
      final streetLower = street.toLowerCase();
      final cityLower = city.toLowerCase();
      if (streetLower.contains(cityLower)) return street;
      return '$street, $city';
    }
    return street ?? city ?? clean(place.country);
  }
}
