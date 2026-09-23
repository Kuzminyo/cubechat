import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'airdrop_source.dart';

/// Files picked from "Вибрати файли" on the AirDrop section, held while the
/// section stays open — sent to whoever is chosen, or whoever the phone
/// bumps next, without picking the files again for each.
final airdropStagedProvider =
    StateProvider<List<AirDropSource>>((_) => const []);
