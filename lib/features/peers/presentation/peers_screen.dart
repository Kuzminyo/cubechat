import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/identity_avatar.dart';
import '../../../l10n/app_localizations.dart';

/// Placeholder. Real BLE peer discovery lands in M1.
class PeersScreen extends StatelessWidget {
  const PeersScreen({super.key});

  // Throwaway sample peers — visual only.
  static const _samples = [
    ('pk_orion', 'Orion', 1),
    ('pk_lyra', 'Lyra', 2),
    ('pk_atlas', 'Atlas', 3),
  ];

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: Text(
              t.peersTitle,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.5,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
            child: Text(
              t.peersSubtitle,
              style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13),
            ),
          ),
          for (final (id, name, hops) in _samples) ...[
            GlassCard(
              child: Row(
                children: [
                  IdentityAvatar(seed: id, label: name, size: 44, online: true),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: TextStyle(
                            color: AppColors.textOnGlass,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          hops == 1 ? t.peersHopsOne(hops) : t.peersHopsOther(hops),
                          style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: AppColors.textOnGlassFaint),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}
