import 'package:cubechat/features/map/data/map_address_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart';

void main() {
  test('shows street and city in one compact label', () {
    const place = Placemark(street: 'Myr Street, 7', locality: 'Kharkiv');

    expect(MapAddressService.compactLabel(place), 'Myr Street, 7, Kharkiv');
  });

  test('does not repeat a city already present in the street line', () {
    const place = Placemark(street: 'Kyiv, Khreshchatyk 1', locality: 'Kyiv');

    expect(MapAddressService.compactLabel(place), 'Kyiv, Khreshchatyk 1');
  });

  test('falls back from street to city and country', () {
    const city = Placemark(locality: 'Lviv', country: 'Ukraine');
    const country = Placemark(country: 'Ukraine');

    expect(MapAddressService.compactLabel(city), 'Lviv');
    expect(MapAddressService.compactLabel(country), 'Ukraine');
  });
}
