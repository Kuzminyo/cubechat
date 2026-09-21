import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/theme/typography.dart';
import '../../../../core/transport/messaging_service.dart';
import '../../../../core/widgets/floating_glass.dart';
import '../../../../l10n/app_localizations.dart';
import '../../data/held_media.dart';

/// "N media waiting for Wi-Fi · Download", above the chat list — only while
/// "wait for Wi-Fi" is holding something back.
///
/// The pause has to be visible to be a choice. A photo or voice note held on
/// the relay has no bubble until its chunks arrive, so without this row a
/// held note is indistinguishable from one that was never sent. Beside the
/// send queue's row, because it is the same question asked the other way
/// round: what is waiting for a better connection.
class HeldMediaEntry extends ConsumerWidget {
  const HeldMediaEntry({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(
      heldMediaProvider.select((m) => m.values.fold<int>(0, (a, b) => a + b)),
    );
    if (count == 0) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: FloatingGlass(
        blur: false,
        borderRadius: 18,
        onTap: () => ref.read(messagingServiceProvider).resumeMediaInbox(),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          child: Row(
            children: [
              Icon(
                Icons.wifi_rounded,
                size: 20,
                color: AppColors.textOnGlassDim,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  t.heldMediaCount(count),
                  style: AppTypography.rowTitle,
                ),
              ),
              TextButton(
                onPressed: () =>
                    ref.read(messagingServiceProvider).resumeMediaInbox(),
                child: Text(
                  t.heldMediaDownload,
                  style: TextStyle(
                    color: AppColors.brandPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
