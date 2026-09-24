import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/transport/messaging_service.dart';
import '../../../core/transport/nearby_offer.dart';
import 'airdrop_source.dart';

/// Files picked from "Вибрати файли" on the AirDrop section, held while the
/// section stays open — sent to whoever is chosen, or whoever the phone
/// bumps next, without picking the files again for each.
///
/// Only ever set to what [vetAirDropFiles] passed: a bump sends the staging
/// with no picker and no person sheet in between, so it gets no second
/// chance at the checks.
final airdropStagedProvider =
    StateProvider<List<AirDropSource>>((_) => const []);

/// The checks every AirDrop send makes before an offer: a file over the
/// Bluetooth cap stops the whole send ([tooLarge] names it and [files] is
/// empty), and more than [nearbyMaxFiles] are cut to the first ones.
///
/// Shared by the send flow and staging for a bump. 1109 staged whatever was
/// picked: 51 files made the bumped `offer()` throw after the card already
/// said "Sending…", and a file over the cap went out unrefused.
({List<AirDropSource> files, AirDropSource? tooLarge}) vetAirDropFiles(
  List<AirDropSource> chosen,
) {
  for (final f in chosen) {
    if (f.size > MessagingService.maxFileBytesMesh) {
      return (files: const [], tooLarge: f);
    }
  }
  return (
    files: chosen.length > nearbyMaxFiles
        ? chosen.take(nearbyMaxFiles).toList()
        : chosen,
    tooLarge: null,
  );
}
