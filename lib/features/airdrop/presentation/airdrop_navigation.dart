import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The AirDrop page's place on the Nearby tab (Nearby | AirDrop | Files).
const int kAirDropPage = 1;

/// The notification thread an AirDrop request is raised under. A tap on it
/// comes back through the chat opener with this as the "chat id", which
/// is how the app knows to open the AirDrop page instead.
const String kAirDropNotificationThread = 'cubechat:airdrop';

/// A request to bring one of the Nearby pages to the front — set by the send
/// flow and the incoming banner, taken and cleared by the Nearby screen.
final nearbyPageRequestProvider = StateProvider<int?>((ref) => null);

/// Whether the AirDrop page is what the person is looking at, so the incoming
/// banner does not cover the very card it would repeat.
final airdropPageOnScreenProvider = StateProvider<bool>((ref) => false);
