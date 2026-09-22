import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/transport/chat_session_manager.dart';
import '../../../core/transport/messaging_service.dart';
import '../../../core/widgets/floating_glass.dart';
import '../../../core/widgets/glass_sheet.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../l10n/app_localizations.dart';
import '../../peers/data/peripheral_controller.dart';
import '../data/airdrop_controller.dart' show airdropPeerNameProvider;

@immutable
class AirDropPeer {
  const AirDropPeer(this.hex, this.name);

  final String hex;
  final String name;
}

/// Everyone with a Bluetooth session to this phone right now — the only
/// people AirDrop can reach. Recomputed when sessions or peripheral links
/// change.
final airdropDirectPeersProvider = Provider<List<AirDropPeer>>((ref) {
  ref.watch(chatSessionManagerProvider);
  ref.watch(peripheralControllerProvider);
  final names = ref.watch(airdropPeerNameProvider);
  return [
    for (final hex in ref.watch(messagingServiceProvider).directPeerHexes())
      AirDropPeer(hex, names(hex)),
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
});

Future<AirDropPeer?> showAirDropPeopleSheet(BuildContext context) =>
    showGlassSheet<AirDropPeer>(
      context: context,
      useRootNavigator: true,
      builder: (sheet) => AirDropPeopleList(
        onPick: (peer) => Navigator.of(sheet).pop(peer),
      ),
    );

class AirDropPeopleList extends ConsumerWidget {
  const AirDropPeopleList({super.key, required this.onPick});

  final ValueChanged<AirDropPeer> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final peers = ref.watch(airdropDirectPeersProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t.airdropPickPerson,
            style:
                AppTypography.heading(size: 18, color: AppColors.textOnGlass),
          ),
          const SizedBox(height: 12),
          if (peers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                t.airdropNobody,
                style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final peer in peers)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: FloatingGlass(
                        blur: false,
                        borderRadius: 16,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        onTap: () => onPick(peer),
                        child: Row(
                          children: [
                            IdentityAvatar(
                              seed: peer.hex,
                              label: peer.name,
                              size: 40,
                              online: true,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                peer.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: AppColors.textOnGlass,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Icon(
                              Icons.bluetooth_connected_rounded,
                              color: AppColors.brandPrimary,
                              size: 18,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
