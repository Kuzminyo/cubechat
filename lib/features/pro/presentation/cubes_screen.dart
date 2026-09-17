import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../l10n/app_localizations.dart';
import '../../backup/data/backup_made_controller.dart';
import '../data/cubes_controller.dart';
import '../models/cube_pack.dart';

/// Cubes: what you have, and the ladder of ways to get more.
///
/// **A backup comes before a purchase, and that is the whole screen.**
/// Reinstalling mints a new Nostr key; the balance is tied to that key; a key
/// that is gone takes the cubes with it. Somebody who loses money that way is
/// right to ask for it back, and the only honest place to prevent it is
/// before they spend it. So until this device has written a backup, this
/// screen offers to make one instead of offering to sell anything.
class CubesScreen extends ConsumerWidget {
  const CubesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final cubes = ref.watch(cubesProvider);
    final backedUp = ref.watch(backupMadeProvider) != null;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: BackButton(color: AppColors.textOnGlass),
        title: Text(
          t.cubesTitle,
          style: AppTypography.heading(size: 18, color: AppColors.textOnGlass),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            _Balance(cubes: cubes.balance, loaded: cubes.loaded),
            const SizedBox(height: 20),
            if (!backedUp)
              _BackupFirst(onMake: () => context.push('/backup'))
            else
              ...CubePack.ladder.map(
                (pack) => _PackRow(
                  pack: pack,
                  price: cubes.priceOf(pack) ?? pack.listPrice,
                  busy: cubes.buying == pack.storeId,
                  onTap: () => ref.read(cubesProvider.notifier).buy(pack),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Balance extends StatelessWidget {
  const _Balance({required this.cubes, required this.loaded});

  final int cubes;
  final bool loaded;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Column(
      children: [
        const SizedBox(height: 8),
        Text(
          // A dash until the server has answered. Showing zero to somebody who
          // has a balance is worse than showing nothing.
          loaded ? '$cubes' : '—',
          style: AppTypography.display(size: 44, color: AppColors.brandPrimary),
        ),
        const SizedBox(height: 4),
        Text(
          t.cubesBalance,
          style: TextStyle(color: AppColors.textOnGlassDim),
        ),
      ],
    );
  }
}

/// What this screen shows instead of a shop, until there is a backup.
class _BackupFirst extends StatelessWidget {
  const _BackupFirst({required this.onMake});

  final VoidCallback onMake;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.cubesBackupFirstTitle,
            style: AppTypography.heading(
              size: 16,
              color: AppColors.textOnGlass,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            t.cubesBackupFirstBody,
            style: TextStyle(
              color: AppColors.textOnGlassDim,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: OutlinedButton(
              onPressed: onMake,
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: AppColors.brandPrimary, width: 1.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(23),
                ),
              ),
              child: Text(
                t.cubesBackupFirstAction,
                style: AppTypography.heading(
                  size: 15,
                  color: AppColors.brandPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PackRow extends StatelessWidget {
  const _PackRow({
    required this.pack,
    required this.price,
    required this.busy,
    required this.onTap,
  });

  final CubePack pack;
  final String price;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 10),
      onTap: busy ? null : onTap,
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${pack.cubes}',
              style: AppTypography.heading(
                size: 17,
                color: AppColors.textOnGlass,
              ),
            ),
          ),
          if (busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Text(
              price,
              style: AppTypography.mono(
                size: 14,
                color: AppColors.textOnGlassDim,
              ),
            ),
        ],
      ),
    );
  }
}
