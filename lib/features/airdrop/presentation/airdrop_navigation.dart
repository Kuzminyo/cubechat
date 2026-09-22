import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The AirDrop page's place on the Nearby tab (Nearby | AirDrop | Files).
const int kAirDropPage = 1;

/// A request to bring one of the Nearby pages to the front — set by the send
/// flow and the incoming banner, taken and cleared by the Nearby screen.
final nearbyPageRequestProvider = StateProvider<int?>((ref) => null);

/// Whether the AirDrop page is what the person is looking at, so the incoming
/// banner does not cover the very card it would repeat.
final airdropPageOnScreenProvider = StateProvider<bool>((ref) => false);
