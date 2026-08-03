import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../l10n/app_localizations.dart';

class PhoneTransferCard extends StatelessWidget {
  const PhoneTransferCard({super.key, this.framed = true});

  /// False when a settings group already supplies the pane of glass around it.
  final bool framed;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final content = Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.brandSecondary.withValues(alpha: .18),
              border: Border.all(
                color: AppColors.brandSecondary.withValues(alpha: .4),
              ),
            ),
            child: Icon(
              Icons.phonelink_ring_rounded,
              color: AppColors.brandSecondary,
              size: 19,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.phoneTransferTitle,
                  style: TextStyle(
                    color: AppColors.textOnGlass,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  t.phoneTransferSameWifi,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textOnGlassDim,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: AppColors.textOnGlassFaint),
        ],
    );

    void open() => context.push('/phone-transfer');

    if (framed) return GlassCard(onTap: open, child: content);
    return InkWell(
      onTap: open,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: content,
      ),
    );
  }
}
