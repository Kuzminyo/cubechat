import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/widgets/glass_sheet.dart';
import '../../../l10n/app_localizations.dart';
import '../../peers/presentation/widgets/peer_avatar.dart';
import '../data/map_focus_request.dart';

/// One person in a huddle of pins, as the sheet needs them.
@immutable
class MapClusterMember {
  const MapClusterMember({
    required this.peerId,
    required this.name,
    this.detail,
  });

  final String peerId;
  final String name;

  /// How far away and how long ago — the same line the card on the map shows.
  final String? detail;
}

/// Who is standing in that one circle on the map.
///
/// A cluster answers "several people are here"; this answers "which people",
/// which is the next thing anybody wants and the only way to reach somebody
/// whose pin is underneath three others. Tapping a name takes the camera to
/// them, exactly as tapping their pin would have, had it been reachable.
Future<void> showMapClusterSheet(
  BuildContext context,
  List<MapClusterMember> members,
) =>
    showGlassSheet<void>(
      context: context,
      useRootNavigator: true,
      builder: (_) => _MapClusterSheet(members: members),
    );

class _MapClusterSheet extends ConsumerWidget {
  const _MapClusterSheet({required this.members});

  final List<MapClusterMember> members;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final height = MediaQuery.sizeOf(context).height * 0.6;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: height),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.glass(0.24),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.brandPrimary.withValues(alpha: 0.14),
                    ),
                    child: Icon(
                      Icons.groups_rounded,
                      color: AppColors.brandPrimary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.mapClusterTitle(members.length),
                          style: TextStyle(
                            color: AppColors.textOnGlass,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          t.mapClusterHint,
                          style: TextStyle(
                            color: AppColors.textOnGlassDim,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: members.length,
                itemBuilder: (_, index) {
                  final member = members[index];
                  return ListTile(
                    leading: PeerAvatar(
                      peerId: member.peerId,
                      label: member.name,
                      size: 42,
                      online: true,
                    ),
                    title: Text(
                      member.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: AppColors.textOnGlass),
                    ),
                    subtitle: member.detail == null
                        ? null
                        : Text(
                            member.detail!,
                            style: TextStyle(
                              color: AppColors.textOnGlassDim,
                              fontSize: 11.5,
                            ),
                          ),
                    trailing: Icon(
                      Icons.my_location_rounded,
                      color: AppColors.brandPrimary,
                      size: 20,
                    ),
                    onTap: () {
                      Navigator.of(context).pop();
                      ref.read(mapFocusRequestProvider.notifier).state =
                          MapFocusRequest(member.peerId);
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
