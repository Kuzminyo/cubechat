import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../l10n/app_localizations.dart';
import '../data/pro_controller.dart';
import '../models/pro_state.dart';

/// What Pro is, and the three ways to buy it.
///
/// Prices are not on this screen yet: they come from the store, and the
/// products do not exist there until they are registered. Names first, sums in
/// the task after.
///
/// Nothing in the app reads [proProvider] to decide anything — that is the
/// point of the first step. This screen is where the purchase is proved
/// against the live stores before a single feature depends on it.
class ProScreen extends ConsumerWidget {
  const ProScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context);
    final pro = ref.watch(proProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: BackButton(color: AppColors.textOnGlass),
        title: Text(
          t.proTitle,
          style: AppTypography.heading(size: 18, color: AppColors.textOnGlass),
        ),
      ),
      body: SafeArea(
        top: false,
        child: _body(context, ref, t, pro),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations t,
    ProState pro,
  ) {
    // Not known yet is not the same as no. Drawing the pitch here would show
    // it for a frame on every cold start to somebody who already paid.
    if (!pro.loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    if (pro.isActive) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 140),
        children: [
          GlassCard(
            child: Text(
              t.proActive,
              style: TextStyle(color: AppColors.textOnGlass),
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 140),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(
            t.proBlurb,
            style: TextStyle(color: AppColors.textOnGlassDim),
          ),
        ),
        // The card is the button: `GlassCard` already takes an `onTap`, and a
        // pill inside a card repeats the product name twice on one row.
        for (final product in ProProduct.values)
          GlassCard(
            margin: const EdgeInsets.only(bottom: 12),
            onTap: () => ref.read(proProvider.notifier).buy(product),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _label(t, product),
                  style: AppTypography.heading(
                    size: 16,
                    color: AppColors.textOnGlass,
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.textOnGlassDim,
                ),
              ],
            ),
          ),
        TextButton(
          onPressed: () => ref.read(proProvider.notifier).restore(),
          child: Text(
            t.proRestore,
            style: TextStyle(color: AppColors.textOnGlassDim),
          ),
        ),
      ],
    );
  }

  String _label(AppLocalizations t, ProProduct product) => switch (product) {
        ProProduct.monthly => t.proMonthly,
        ProProduct.yearly => t.proYearly,
        ProProduct.lifetime => t.proLifetime,
      };
}
