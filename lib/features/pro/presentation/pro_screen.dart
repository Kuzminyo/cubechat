import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/typography.dart';
import '../../../core/widgets/cube_logo.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/glass_toast.dart';
import '../../../l10n/app_localizations.dart';
import '../data/pro_controller.dart';
import '../models/pro_state.dart';

/// What Pro is, and the three ways to buy it.
///
/// Built out of the app's own language rather than a paywall borrowed from
/// somewhere else: the palette through [AppColors], one pane of glass, the
/// cube, and hairlines between the rows. An earlier pass drew a fixed violet
/// gradient and colour-tiled icons, which read as another messenger's screen
/// pasted into this one.
///
/// Prices are whatever the store says. Until the products are registered there
/// the line is a dash — a number invented for a mockup is the kind of
/// placeholder that ships.
class ProScreen extends ConsumerStatefulWidget {
  const ProScreen({super.key});

  @override
  ConsumerState<ProScreen> createState() => _ProScreenState();
}

class _ProScreenState extends ConsumerState<ProScreen> {
  /// Yearly first and selected, because it is the one worth taking.
  ProProduct _selected = ProProduct.yearly;

  Future<void> _buy() async {
    final t = AppLocalizations.of(context);
    final started = await ref.read(proProvider.notifier).buy(_selected);
    if (!mounted || started) return;
    // The product is not registered in the store yet. That is a thing to say
    // to the person, not a fault to log.
    showGlassToast(context, t.proUnavailable);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final pro = ref.watch(proProvider);
    final prices = ref.watch(proPricesProvider).valueOrNull ?? const {};

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: BackButton(color: AppColors.textOnGlass),
      ),
      body: SafeArea(top: false, child: _body(t, pro, prices)),
    );
  }

  Widget _body(
    AppLocalizations t,
    ProState pro,
    Map<ProProduct, String> prices,
  ) {
    // Not known yet is not the same as no. Drawing the pitch here would show
    // it for a frame on every cold start to somebody who already paid.
    if (!pro.loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    if (pro.isActive) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CubeLogo(size: 88, glow: true),
              const SizedBox(height: 22),
              Text(
                t.proActive,
                textAlign: TextAlign.center,
                style: AppTypography.display(
                  size: 21,
                  color: AppColors.textOnGlass,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        const Center(child: CubeLogo(size: 88, glow: true)),
        const SizedBox(height: 20),
        Text(
          t.proTitle,
          textAlign: TextAlign.center,
          style: AppTypography.display(size: 26, color: AppColors.textOnGlass),
        ),
        const SizedBox(height: 8),
        Text(
          t.proBlurb,
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textOnGlassDim, height: 1.4),
        ),
        const SizedBox(height: 22),
        GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            // Stretch, or GlassCard centres each row and the three left edges
            // come out ragged.
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _FeatureRow(
                title: t.proFeatureIconTitle,
                body: t.proFeatureIconBody,
              ),
              _divider(),
              _FeatureRow(
                title: t.proFeatureStickersTitle,
                body: t.proFeatureStickersBody,
              ),
              _divider(),
              _FeatureRow(
                title: t.proFeatureBackupTitle,
                body: t.proFeatureBackupBody,
              ),
              _divider(),
              _FeatureRow(
                title: t.proFeatureSaveTitle,
                body: t.proFeatureSaveBody,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _Segmented(
          labels: {
            for (final p in ProProduct.values) p: _label(t, p),
          },
          selected: _selected,
          onSelect: (p) => setState(() => _selected = p),
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            // The store's price when it has one, and the list price until the
            // products are registered there. See [ProProduct.listPrice] for
            // why the store's answer is the one that is true.
            '${prices[_selected] ?? _selected.listPrice}  '
            '${_period(t, _selected)}',
            style: AppTypography.mono(
              size: 13,
              color: AppColors.textOnGlassDim,
            ),
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          height: 52,
          child: OutlinedButton(
            onPressed: _buy,
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: AppColors.brandPrimary, width: 1.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(26),
              ),
            ),
            child: Text(
              _selected == ProProduct.lifetime ? t.proBuyOnce : t.proSubscribe,
              style: AppTypography.heading(
                size: 16,
                color: AppColors.brandPrimary,
              ),
            ),
          ),
        ),
        Center(
          child: TextButton(
            onPressed: () => ref.read(proProvider.notifier).restore(),
            child: Text(
              t.proRestore,
              style: TextStyle(color: AppColors.textOnGlassDim),
            ),
          ),
        ),
      ],
    );
  }

  Widget _divider() => Divider(
        height: 1,
        thickness: 1,
        color: AppColors.glassBorder,
      );

  String _label(AppLocalizations t, ProProduct product) => switch (product) {
        ProProduct.monthly => t.proMonthly,
        ProProduct.yearly => t.proYearly,
        ProProduct.lifetime => t.proLifetime,
      };

  String _period(AppLocalizations t, ProProduct product) => switch (product) {
        ProProduct.monthly => t.proPerMonth,
        ProProduct.yearly => t.proPerYear,
        ProProduct.lifetime => t.proOnce,
      };
}

/// One thing Pro adds, as a line of text — no icon tile.
class _FeatureRow extends StatelessWidget {
  const _FeatureRow({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: AppTypography.heading(
              size: 15,
              color: AppColors.textOnGlass,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            body,
            style: TextStyle(
              fontSize: 13,
              color: AppColors.textOnGlassDim,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

/// Which plan, as one control rather than three cards.
class _Segmented extends StatelessWidget {
  const _Segmented({
    required this.labels,
    required this.selected,
    required this.onSelect,
  });

  final Map<ProProduct, String> labels;
  final ProProduct selected;
  final ValueChanged<ProProduct> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.ink(0.07),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          for (final entry in labels.entries)
            Expanded(
              child: GestureDetector(
                onTap: () => onSelect(entry.key),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: entry.key == selected
                        ? AppColors.brandPrimary
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    entry.value,
                    textAlign: TextAlign.center,
                    style: AppTypography.heading(
                      size: 13,
                      color: entry.key == selected
                          ? AppColors.bgDeep
                          : AppColors.textOnGlassDim,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
